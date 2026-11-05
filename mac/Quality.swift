// Judges a recording's real quality (lossless, lossy, or upsampled from a lower sample rate) by running the shared
// web/audio-quality.js in the JavaScriptCore that ships with macOS, so the Mac, Windows and web versions agree.
import AVFoundation
import JavaScriptCore

struct QualityReport: Equatable {
    let verdict: String
    // A word or two for the list, such as "Lossy" or "22.05 kHz". Empty when there's nothing to judge.
    let label: String
    let summary: String
}

struct QualityChecker {
    let script: String

    // The app carries the script in its bundle; the self-check reads it from the web folder.
    init(scriptURL: URL? = Bundle.main.url(forResource: "audio-quality", withExtension: "js")) throws {
        guard let scriptURL else { throw CocoaError(.fileNoSuchFile) }
        script = try String(contentsOf: scriptURL, encoding: .utf8)
    }

    // Reads only the parts of the file the script asks for (about 36 seconds in all), so long recordings stay quick.
    func check(_ url: URL) throws -> QualityReport {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)

        guard let context = JSContext() else { throw CocoaError(.featureUnsupported) }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(script)
        let api = context.objectForKeyedSubscript("AudioQuality")
        let ranges = (api?.invokeMethod("excerptRanges", withArguments: [file.length, format.sampleRate])?
            .toArray() as? [NSNumber])?.map(\.intValue)
        guard failure == nil, let api, let ranges else { throw scriptError(failure) }

        let total = stride(from: 1, to: ranges.count, by: 2).reduce(0) { $0 + ranges[$1] }
        // JavaScript takes ownership of this memory and frees it when the array is collected.
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, total * channels))
        var filled = 0
        do {
            for index in stride(from: 0, to: ranges.count, by: 2) {
                let length = AVAudioFrameCount(ranges[index + 1])
                guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { continue }
                file.framePosition = AVAudioFramePosition(ranges[index])
                try file.read(into: buffer, frameCount: length)
                guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<channels {
                        samples[filled + frame * channels + channel] = data[channel][frame]
                    }
                }
                filled += Int(buffer.frameLength) * channels
            }
        } catch {
            samples.deallocate()
            throw error
        }

        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kJSTypedArrayTypeFloat32Array, samples, filled * MemoryLayout<Float>.size,
            { bytes, _ in bytes?.deallocate() }, nil, &exception)
        guard let array, exception == nil else {
            samples.deallocate()
            throw scriptError(JSValue(jsValueRef: exception, in: context)?.toString())
        }

        let report = api.invokeMethod("analyzeExcerpts", withArguments: [
            JSValue(jsValueRef: array, in: context) as Any, channels, format.sampleRate, ranges,
        ])
        guard failure == nil, let report else { throw scriptError(failure) }
        return QualityReport(verdict: report.forProperty("verdict").toString(),
                             label: report.forProperty("label").toString(),
                             summary: report.forProperty("summary").toString())
    }

    private func scriptError(_ message: String?) -> Error {
        NSError(domain: "AudioQuality", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The quality check failed: \(message ?? "no result")",
        ])
    }
}
