// Saves captured audio to a 32-bit float .wav, starting at the first non-zero sample and keeping pauses as silence.
import AVFoundation

final class RecordingFile {
    private let url: URL
    private var file: AVAudioFile?
    private var expectedTime: Double?

    var hasStarted: Bool { file != nil }

    init(url: URL) {
        self.url = url
    }

    func append(_ sample: CMSampleBuffer) throws {
        guard let description = sample.formatDescription else { throw CocoaError(.fileWriteUnknown) }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat == .pcmFormatFloat32 else { throw CocoaError(.fileWriteUnknown) }

        var startFrame = 0
        if file == nil {
            guard let first = firstNonZeroFrame(in: try pcmBuffer(from: sample, format: format, startFrame: 0)) else { return }
            startFrame = first
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        }
        guard let file else { return }

        let time = sample.presentationTimeStamp.seconds + Double(startFrame) / format.sampleRate
        // Capture can skip time while an app is quiet, so the missing time is written back as silence.
        // Gaps under 10ms are ordinary timing jitter, and filling them would add clicks.
        if let expectedTime, time - expectedTime > 0.01 {
            try writeSilence(to: file, frames: Int(((time - expectedTime) * format.sampleRate).rounded()), format: format)
        }
        let buffer = try pcmBuffer(from: sample, format: format, startFrame: startFrame)
        try file.write(from: buffer)
        expectedTime = time + Double(buffer.frameLength) / format.sampleRate
    }

    private func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat, startFrame: Int) throws -> AVAudioPCMBuffer {
        let frames = sample.numSamples - startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: Int32(startFrame), frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return buffer
    }

    private func firstNonZeroFrame(in buffer: AVAudioPCMBuffer) -> Int? {
        var first: Int?
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData else { continue }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(channel.mDataByteSize) / MemoryLayout<Float>.size)
            if let index = samples.firstIndex(where: { $0 != 0 }) {
                let frame = index / Int(channel.mNumberChannels)
                first = min(first ?? frame, frame)
            }
        }
        return first
    }

    private func writeSilence(to file: AVAudioFile, frames: Int, format: AVAudioFormat) throws {
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        silence.frameLength = chunk
        for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = min(chunk, AVAudioFrameCount(remaining))
            try file.write(from: silence)
            remaining -= Int(silence.frameLength)
        }
    }
}
