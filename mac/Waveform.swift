// Reduces an audio file to a short list of loudness values, one for each bar of the drawn waveform.
import AVFoundation

func waveformPeaks(of url: URL, bars: Int = 400) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    var peaks = [Float](repeating: 0, count: bars)
    guard file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)
    else { return peaks }

    var position: Int64 = 0
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        for frame in 0..<Int(buffer.frameLength) {
            let bar = min(bars - 1, Int((position + Int64(frame)) * Int64(bars) / file.length))
            for channel in 0..<Int(buffer.format.channelCount) {
                peaks[bar] = max(peaks[bar], abs(channels[channel][frame]))
            }
        }
        position += Int64(buffer.frameLength)
    }

    return fitWaveform(peaks, bars: bars)
}

// Holds a recording's loudness as it grows, merging older values so redrawing stays quick however long it runs.
struct LoudnessHistory {
    private(set) var values: [Float] = []
    private var reportsPerValue = 1
    private var pendingReports = 0

    mutating func append(_ value: Float, bars: Int = 400) {
        if pendingReports == 0 {
            values.append(value)
        } else {
            values[values.count - 1] = max(values[values.count - 1], value)
        }
        pendingReports += 1
        guard pendingReports == reportsPerValue else { return }
        pendingReports = 0
        guard values.count == bars * 2 else { return }
        values = stride(from: 0, to: values.count, by: 2).map { max(values[$0], values[$0 + 1]) }
        reportsPerValue *= 2
    }
}

// Squeezes loudness values into at most `bars`, scaled to the loudest so quiet audio is still readable.
func fitWaveform(_ values: [Float], bars: Int = 400) -> [Float] {
    var fitted = values
    if values.count > bars {
        fitted = [Float](repeating: 0, count: bars)
        for (index, value) in values.enumerated() {
            let bar = index * bars / values.count
            fitted[bar] = max(fitted[bar], value)
        }
    }
    let loudest = fitted.max() ?? 0
    return loudest > 0 ? fitted.map { $0 / loudest } : fitted
}
