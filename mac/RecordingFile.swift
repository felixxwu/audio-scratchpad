// Saves captured audio to a 32-bit float .wav, starting at the first non-zero sample and keeping pauses as silence.
import AVFoundation

final class RecordingFile {
    // WAV sizes are 32-bit, which limits a stereo recording to about 3 hours.
    static let largestDataSize = Int64(UInt32.max) - 44

    private let url: URL
    private let maxDataSize: Int64
    private var file: FileHandle?
    private var expectedTime: Double?
    private var dataSize: Int64 = 0

    var hasStarted: Bool { file != nil }

    init(url: URL, maxDataSize: Int64 = RecordingFile.largestDataSize) {
        self.url = url
        self.maxDataSize = maxDataSize
    }

    func append(_ sample: CMSampleBuffer) throws {
        guard let description = sample.formatDescription else { throw CocoaError(.fileWriteUnknown) }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatFloat32 else { throw CocoaError(.fileWriteUnknown) }
        let channels = Int(format.channelCount)
        var samples = try interleavedSamples(of: sample, format: format)

        var time = sample.presentationTimeStamp.seconds
        if file == nil {
            guard let first = samples.firstIndex(where: { $0 != 0 }) else { return }
            let startFrame = first / channels
            samples.removeFirst(startFrame * channels)
            time += Double(startFrame) / format.sampleRate
            // Fails rather than overwrites if a recording of this name already exists.
            try Data().write(to: url, options: .withoutOverwriting)
            let created = try FileHandle(forWritingTo: url)
            try writeHeader(to: created, sampleRate: UInt32(format.sampleRate), channels: UInt16(channels))
            file = created
        }
        guard let file else { return }

        // Capture can skip time while an app is quiet, so the missing time is written back as silence.
        // Gaps under 10ms are ordinary timing jitter, and filling them would add clicks.
        var silentFrames = 0
        if let expectedTime, time - expectedTime > 0.01 {
            silentFrames = Int(((time - expectedTime) * format.sampleRate).rounded())
        }
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        guard dataSize + Int64((silentFrames + samples.count / channels) * bytesPerFrame) <= maxDataSize else {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [
                NSLocalizedDescriptionKey: "The recording reached the largest size a WAV file can hold.",
            ])
        }

        if silentFrames > 0 {
            // Growing a file fills the new space with zeros, so the pause needs no loop of writes.
            dataSize += Int64(silentFrames * bytesPerFrame)
            try file.truncate(atOffset: UInt64(44 + dataSize))
        }
        try file.seekToEnd()
        let bytes = samples.withUnsafeBytes { Data($0) }
        try file.write(contentsOf: bytes)
        dataSize += Int64(bytes.count)
        expectedTime = time + Double(samples.count / channels) / format.sampleRate

        // Kept current after every write, so a crash still leaves a playable file.
        try writeHeader(to: file, sampleRate: UInt32(format.sampleRate), channels: UInt16(channels))
    }

    private func interleavedSamples(of sample: CMSampleBuffer, format: AVAudioFormat) throws -> [Float] {
        let frames = sample.numSamples
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData
        else { throw CocoaError(.fileWriteOutOfSpace) }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }

        let channels = Int(format.channelCount)
        if format.isInterleaved {
            return Array(UnsafeBufferPointer(start: data[0], count: frames * channels))
        }
        var samples = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            for frame in 0..<frames { samples[frame * channels + channel] = data[channel][frame] }
        }
        return samples
    }

    private func writeHeader(to file: FileHandle, sampleRate: UInt32, channels: UInt16) throws {
        var header = Data()
        func add<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        let bytesPerFrame = channels * 4
        header.append(contentsOf: "RIFF".utf8)
        add(UInt32(36 + dataSize))
        header.append(contentsOf: "WAVEfmt ".utf8)
        add(UInt32(16))
        add(UInt16(3)) // IEEE float
        add(channels)
        add(sampleRate)
        add(sampleRate * UInt32(bytesPerFrame))
        add(bytesPerFrame)
        add(UInt16(32))
        header.append(contentsOf: "data".utf8)
        add(UInt32(dataSize))
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header)
    }
}
