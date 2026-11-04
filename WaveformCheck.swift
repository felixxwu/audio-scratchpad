// Fails the build if waveforms are drawn wrongly, or recordings don't start, pause and store samples as intended.
import AVFoundation

private func sampleBuffer(at seconds: Double, values: [Float]) -> CMSampleBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
    pcm.frameLength = AVAudioFrameCount(values.count)
    for channel in 0..<2 {
        for (frame, value) in values.enumerated() { pcm.floatChannelData![channel][frame] = value }
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
    }

    let file = try AVAudioFile(forReading: url)
    let format = file.fileFormat.settings
    precondition(format[AVLinearPCMIsFloatKey] as? Bool == true, "file should store float samples")
    precondition(format[AVLinearPCMBitDepthKey] as? Int == 32, "file should store 32-bit samples")
    precondition(file.length == 2 + 48000 + 2, "should drop the lead-in and keep the pause, got \(file.length)")

    let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: read)
    let samples = read.floatChannelData![0]
    precondition(samples[0] == 1.5, "should start on the first non-zero sample and keep peaks above full scale")
    precondition(samples[1] == 0.25, "should keep the rest of the first buffer")
    precondition((2..<48002).allSatisfy { samples[$0] == 0 }, "the pause should be silent")
    precondition(samples[48002] == 0.5, "audio should resume after the pause")
    _ = try AVAudioPlayer(contentsOf: url)
}

@main
struct WaveformCheck {
    static func main() throws {
        try checkRecordingFile()

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
        print("Waveform check passed")
    }
}
