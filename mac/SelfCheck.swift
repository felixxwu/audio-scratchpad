// Fails the build if waveforms are drawn wrongly, or recordings don't start, pause and store samples as intended.
import AVFoundation

private func sampleBuffer(at seconds: Double, values: [Float], interleaved: Bool = false) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
    pcm.frameLength = AVAudioFrameCount(values.count)
    for (frame, value) in values.enumerated() {
        if interleaved {
            pcm.floatChannelData![0][frame * 2] = value
            pcm.floatChannelData![0][frame * 2 + 1] = value
        } else {
            pcm.floatChannelData![0][frame] = value
            pcm.floatChannelData![1][frame] = value
        }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                    presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
                                    decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                      refcon: nil, formatDescription: format.formatDescription,
                                      sampleCount: values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil,
                                                                blockBufferMemoryAllocator: nil, flags: 0,
                                                                bufferList: pcm.audioBufferList) == noErr)
    return sample!
}

private func checkRecordingFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-check-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let recording = RecordingFile(url: url)
        try recording.append(sampleBuffer(at: 100, values: [0, 0, 0, 0]))
        precondition(!recording.hasStarted, "silence alone should not start a recording")
        precondition(!FileManager.default.fileExists(atPath: url.path), "silence alone should not create a file")

        try recording.append(sampleBuffer(at: 101, values: [0, 0, 1.5, 0.25]))
        precondition(recording.hasStarted, "a non-zero sample should start the recording")
        // The first buffer ends at 101 + 4 frames, so this leaves a one second pause.
        try recording.append(sampleBuffer(at: 102 + 4.0 / 48000, values: [0.5, 0.5]))
        let crashed = try AVAudioFile(forReading: url)
        precondition(crashed.length == 2 + 48000 + 2, "a file still being written should already be playable, got \(crashed.length)")
        // Jitter under 10ms must not add silence.
        try recording.append(sampleBuffer(at: 102 + 6.0 / 48000 + 0.005, values: [0.75]))
        try recording.append(sampleBuffer(at: 102 + 7.0 / 48000 + 0.005, values: [0.125], interleaved: true))
    }

    let file = try AVAudioFile(forReading: url)
    let format = file.fileFormat.settings
    precondition(format[AVLinearPCMIsFloatKey] as? Bool == true, "file should store float samples")
    precondition(format[AVLinearPCMBitDepthKey] as? Int == 32, "file should store 32-bit samples")
    precondition(file.length == 2 + 48000 + 2 + 2, "should drop the lead-in and keep the pause, got \(file.length)")

    let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: read)
    let samples = read.floatChannelData![0]
    precondition(samples[0] == 1.5, "should start on the first non-zero sample and keep peaks above full scale")
    precondition(samples[1] == 0.25, "should keep the rest of the first buffer")
    precondition((2..<48002).allSatisfy { samples[$0] == 0 }, "the pause should be silent")
    precondition(samples[48002] == 0.5, "audio should resume after the pause")
    precondition(samples[48004] == 0.75, "jitter should not add silence")
    precondition(samples[48005] == 0.125, "interleaved audio should be stored the same way")
    _ = try AVAudioPlayer(contentsOf: url)

    let bytes = try Data(contentsOf: url)
    let dataSize = (2 + 48000 + 2 + 2) * 8
    func headerValue(at offset: Int) -> Int {
        Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }
    precondition(bytes.count == 44 + dataSize, "file should be the header plus the samples, got \(bytes.count)")
    precondition(headerValue(at: 4) == 36 + dataSize, "header should store the right file size")
    precondition(headerValue(at: 40) == dataSize, "header should store the right audio size")

    do {
        let recording = RecordingFile(url: url, maxDataSize: 16)
        try? FileManager.default.removeItem(at: url)
        try recording.append(sampleBuffer(at: 0, values: [1, 1]))
        var stopped = false
        do { try recording.append(sampleBuffer(at: 2.0 / 48000, values: [1])) } catch { stopped = true }
        precondition(stopped, "should stop before the file outgrows what a WAV can hold")
        let full = try AVAudioFile(forReading: url)
        precondition(full.length == 2, "a full recording should stay playable")

        let second = RecordingFile(url: url)
        var refused = false
        do { try second.append(sampleBuffer(at: 0, values: [1])) } catch { refused = true }
        precondition(refused, "should never overwrite an existing recording")
    }

    do {
        try FileManager.default.removeItem(at: url)
        let recording = RecordingFile(url: url, maxDataSize: 24)
        try recording.append(sampleBuffer(at: 0, values: [1, 1]))
        var stopped = false
        do { try recording.append(sampleBuffer(at: 1, values: [1])) } catch { stopped = true }
        precondition(stopped, "a pause should count towards the largest size")
        let size = try Data(contentsOf: url).count
        precondition(size == 44 + 16, "a refused pause should leave the file unchanged, got \(size)")
    }
}

// Runs real recordings through the shared quality check, to catch mistakes in handing audio to JavaScript. The check's
// own judgement is tested against real music in quality/.
private func checkQuality() throws {
    let checker = try QualityChecker(scriptURL: URL(fileURLWithPath: "../web/audio-quality.js"))
    var seed: UInt64 = 1
    func random() -> Double {
        seed = (seed &* 1103515245 &+ 12345) % 2147483648
        return Double(seed) / 2147483648
    }
    func check(_ values: [Float]) throws -> QualityReport {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quality-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile(url: url).append(sampleBuffer(at: 0, values: values))
        return try checker.check(url)
    }

    // A minute of 16-bit noise, the same in both channels, is long enough to be read in parts.
    let noise = (0..<48000 * 60).map { _ in Float(((random() - 0.5) * 16384).rounded() / 32768) }
    let clean = try check(noise)
    precondition(clean.verdict == "lossless" && clean.label == "Lossless", "noise should be lossless, got \(clean)")
    precondition(clean.summary.contains("16-bit"), "samples should reach the check unchanged, got \(clean.summary)")
    precondition(clean.summary.contains("really mono"), "channels should reach the check in order, got \(clean.summary)")

    // A thousand tones below 16 kHz and nothing above, the way a 128 kbps MP3 cuts off.
    var tones = [Float](repeating: 0, count: 48000 * 5)
    for _ in 0..<1000 {
        let step = 2 * Double.pi * (100 + random() * 15900) / 48000
        let phase = random() * 2 * Double.pi
        let (turnRe, turnIm) = (cos(step), sin(step))
        var (re, im) = (cos(phase), sin(phase))
        for index in tones.indices {
            tones[index] += Float(0.002 * re)
            (re, im) = (re * turnRe - im * turnIm, re * turnIm + im * turnRe)
        }
    }
    let lossy = try check(tones)
    precondition(lossy.verdict == "lossy" && lossy.label == "Lossy", "a 16 kHz cutoff should look lossy, got \(lossy)")
}

@main
struct SelfCheck {
    static func main() throws {
        try checkRecordingFile()
        try checkQuality()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-check-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frames: AVAudioFrameCount = 200_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in Int(frames) / 2..<Int(frames) {
            buffer.floatChannelData![1][frame] = frame % 2 == 0 ? 0.5 : -0.5
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let peaks = try waveformPeaks(of: url, bars: 100)
        precondition(peaks.count == 100)
        precondition(peaks[..<50].allSatisfy { $0 == 0 }, "silent half should be flat")
        precondition(peaks[50...].allSatisfy { $0 == 1 }, "loud half should fill the height")
        precondition(fitWaveform([0.25, 0.5]) == [0.5, 1], "short input keeps every value")
        precondition(fitWaveform([0, 0, 0.5, 0.25], bars: 2) == [0, 1], "long input keeps each group's loudest")

        var history = LoudnessHistory()
        for index in 0..<5000 { history.append(index == 1234 ? 1 : 0.1) }
        precondition(history.values.count <= 800, "a long recording's history should stay small")
        precondition(history.values.max() == 1, "merging should keep the loudest moment")
        print("Self-check passed")
    }
}
