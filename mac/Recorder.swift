// Captures one app's audio from ScreenCaptureKit, or the default microphone, into a single file.
import AVFoundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private static let sampleRate = 48000
    private static let framesPerLoudnessValue = sampleRate / 20

    var onUnexpectedStop: ((Error) -> Void)?
    var onLoudness: ((Float) -> Void)?
    var onAudioStarted: (() -> Void)?

    private var pendingLoudness: Float = 0
    private var pendingFrames = 0
    private let queue = DispatchQueue(label: "recorder.audio")
    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    private var microphoneObservers: [NSObjectProtocol] = []
    private var output: RecordingFile?
    private var failed = false

    func start(filter: SCContentFilter, url: URL) async throws {
        output = RecordingFile(url: url)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 2
        // ScreenCaptureKit always captures video too, so keep it as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            _ = await finishWriting()
            throw error
        }
    }

    func startMicrophone(url: URL) async throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No microphone was found."])
        }
        output = RecordingFile(url: url)

        let session = AVCaptureSession()
        session.addInput(try AVCaptureDeviceInput(device: device))
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(audioOutput)

        let center = NotificationCenter.default
        microphoneObservers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CocoaError(.fileReadUnknown)
                self?.onUnexpectedStop?(error)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
                self?.onUnexpectedStop?(CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "The microphone was disconnected.",
                ]))
            },
        ]
        microphone = session
        session.startRunning()
    }

    // Returns false when no audio ever arrived, in which case no file is left behind.
    func stop() async -> Bool {
        try? await stream?.stopCapture()
        stream = nil
        microphoneObservers.forEach(NotificationCenter.default.removeObserver)
        microphoneObservers = []
        microphone?.stopRunning()
        microphone = nil
        return await finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { record(buffer) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        record(buffer)
    }

    private func record(_ buffer: CMSampleBuffer) {
        guard buffer.isValid, buffer.numSamples > 0, !failed, let output else { return }
        let wasStarted = output.hasStarted
        do {
            try output.append(buffer)
        } catch {
            failed = true
            onUnexpectedStop?(error)
            return
        }
        guard output.hasStarted else { return }
        if !wasStarted { onAudioStarted?() }
        reportLoudness(of: buffer)
    }

    // Hands the window one loudness value per 50ms, so it can draw the waveform while recording.
    private func reportLoudness(of buffer: CMSampleBuffer) {
        let loudest = (try? buffer.withAudioBufferList { channels, _ in
            channels.reduce(Float(0)) { result, channel in
                guard let data = channel.mData else { return result }
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                  count: Int(channel.mDataByteSize) / MemoryLayout<Float>.size)
                return samples.reduce(result) { max($0, abs($1)) }
            }
        }) ?? 0
        pendingLoudness = max(pendingLoudness, loudest)
        pendingFrames += buffer.numSamples
        if pendingFrames >= Self.framesPerLoudnessValue {
            onLoudness?(pendingLoudness)
            pendingLoudness = 0
            pendingFrames = 0
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop?(error)
    }

    private func finishWriting() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let saved = output?.hasStarted ?? false
                output = nil
                continuation.resume(returning: saved)
            }
        }
    }
}
