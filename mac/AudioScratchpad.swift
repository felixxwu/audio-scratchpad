// A small Mac app that records the sound of one chosen app, or the microphone, to .wav files and lists them.
import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct Recording: Identifiable {
    let url: URL
    let duration: TimeInterval
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct AudioSource: Identifiable {
    static let microphone = AudioSource()

    let id: String
    let name: String
    let icon: NSImage

    private init() {
        id = "microphone"
        name = "Microphone"
        icon = NSImage(systemSymbolName: "mic", accessibilityDescription: nil) ?? NSImage()
    }

    init?(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        id = bundleID
        name = app.localizedName ?? bundleID
        // Menus draw images at their stored size, so shrink a copy to fit a menu row.
        icon = (app.icon?.copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
    }
}

// The waveform of the recording in progress, kept apart so its updates only redraw that one row.
final class LiveWaveform: ObservableObject {
    @Published private(set) var bars: [Float] = []
    private var history = LoudnessHistory()

    func append(_ value: Float) {
        history.append(value)
        bars = fitWaveform(history.values)
    }

    func reset() {
        history = LoudnessHistory()
        bars = []
    }
}

// Holds everything the window shows: running apps, recording state, saved files and playback.
@MainActor
final class AppModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var sources: [AudioSource] = []
    @Published var selectedSource: String?
    @Published var recordings: [Recording] = []
    @Published var startedAt: Date?
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var isWaitingForAudio = false
    @Published var message: String?
    @Published var needsPermission = false
    private var permissionPane = "Privacy_ScreenCapture"
    @Published var playingURL: URL?
    @Published var waveforms: [URL: [Float]] = [:]
    @Published var qualities: [URL: QualityReport] = [:]
    @Published var copiedURL: URL?

    let live = LiveWaveform()

    private var recorder: Recorder?
    private(set) var currentURL: URL?
    private var player: AVAudioPlayer?

    let folder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Audio Scratchpad", isDirectory: true)

    var isRecording: Bool { startedAt != nil }
    var isCapturing: Bool { isRecording || isWaitingForAudio }

    func refreshSources() {
        sources = [.microphone] + NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap(AudioSource.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !isCapturing, !sources.contains(where: { $0.id == selectedSource }) {
            selectedSource = nil
        }
    }

    func refreshRecordings() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        let listed = urls
            .filter { $0.pathExtension == "wav" && $0 != currentURL }
            .sorted { created($0) > created($1) }
        // Opening every file is slow, and this runs each time the app comes to the front.
        guard listed != recordings.map(\.url) else { return }
        let known = Dictionary(uniqueKeysWithValues: recordings.map { ($0.url, $0) })
        recordings = listed.map { url in
            if let recording = known[url] { return recording }
            let file = try? AVAudioFile(forReading: url)
            let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            return Recording(url: url, duration: duration)
        }
    }

    func loadWaveform(for url: URL) async {
        guard waveforms[url] == nil else { return }
        let peaks = await Task.detached { try? waveformPeaks(of: url) }.value
        waveforms[url] = peaks ?? []
    }

    // Checked one at a time, off the main thread, because each check reads up to 36 seconds of audio.
    private var qualityQueue: Task<Void, Never>?

    func loadQuality(for url: URL) async {
        guard qualities[url] == nil else { return }
        // The check can't tell a microphone's own filter from a lossy encoder's, and the app already knows the answer.
        if url.lastPathComponent.hasPrefix("Microphone ") {
            let tooltip = "Recorded straight from the microphone, so nothing was lost."
            qualities[url] = QualityReport(verdict: "lossless", label: "Lossless", summary: tooltip, tooltip: tooltip)
            return
        }
        let previous = qualityQueue
        let task = Task.detached { () -> QualityReport in
            await previous?.value
            do {
                return try sharedQualityChecker.get().check(url)
            } catch {
                return QualityReport(verdict: "unknown", label: "", summary: error.localizedDescription, tooltip: error.localizedDescription)
            }
        }
        qualityQueue = Task { _ = await task.value }
        qualities[url] = await task.value
    }

    func start() async {
        guard let source = sources.first(where: { $0.id == selectedSource }), !isStarting, !isStopping, !isCapturing else { return }
        isStarting = true
        defer { isStarting = false }
        message = nil
        needsPermission = false
        stopPlayback()
        do {
            var appFilter: SCContentFilter?
            if source.id == AudioSource.microphone.id {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    needsPermission = true
                    permissionPane = "Privacy_Microphone"
                    message = "Audio Scratchpad needs permission to use the microphone. Allow it in System Settings, then try again."
                    return
                }
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first,
                      let app = content.applications.first(where: { $0.bundleIdentifier == source.id })
                else {
                    message = "\(source.name) isn't available to record. Is it still open?"
                    return
                }
                appFilter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            let url = newFileURL(appName: source.name)
            let recorder = Recorder()
            recorder.onUnexpectedStop = { [weak self, weak recorder] error in
                Task { @MainActor in
                    guard let self, let recorder, self.recorder === recorder else { return }
                    await self.stop(reason: error.localizedDescription)
                }
            }
            let live = self.live
            live.reset()
            recorder.onLoudness = { loudness in
                DispatchQueue.main.async { live.append(loudness) }
            }
            recorder.onAudioStarted = { [weak self, weak recorder] in
                Task { @MainActor in
                    guard let self, let recorder, self.recorder === recorder else { return }
                    self.isWaitingForAudio = false
                    self.startedAt = Date()
                }
            }
            currentURL = url
            self.recorder = recorder
            isWaitingForAudio = true
            if let appFilter {
                try await recorder.start(filter: appFilter, url: url)
            } else {
                try await recorder.startMicrophone(url: url)
            }
        } catch {
            recorder = nil
            isWaitingForAudio = false
            currentURL = nil
            show(error)
        }
    }

    func stop(reason: String? = nil) async {
        guard let recorder else { return }
        isStopping = true
        defer { isStopping = false }
        self.recorder = nil
        startedAt = nil
        isWaitingForAudio = false
        let saved = await recorder.stop()
        currentURL = nil
        if let reason {
            message = "Recording stopped: \(reason)"
        } else if !saved {
            message = "No sound came from that source, so nothing was saved."
        }
        refreshSources()
        refreshRecordings()
    }

    func togglePlayback(_ recording: Recording) {
        if playingURL == recording.url {
            stopPlayback()
            return
        }
        play(recording)
    }

    // How far through the current recording playback is, from 0 to 1.
    var playbackProgress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    func seek(_ recording: Recording, to fraction: Double) {
        if playingURL != recording.url { play(recording) }
        guard let player, playingURL == recording.url else { return }
        // Stay just short of the end, so dragging there doesn't finish playback mid-drag.
        player.currentTime = player.duration * min(max(fraction, 0), 0.999)
    }

    private func play(_ recording: Recording) {
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.delegate = self
            player.play()
            self.player = player
            playingURL = recording.url
        } catch {
            show(error)
        }
    }

    // Copies the audio file itself, so it can be pasted into Finder or a chat app.
    func copyToClipboard(_ recording: Recording) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([recording.url as NSURL])
        copiedURL = recording.url
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedURL == recording.url { copiedURL = nil }
        }
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func moveToTrash(_ recording: Recording) {
        if playingURL == recording.url { stopPlayback() }
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        } catch {
            show(error)
        }
        refreshRecordings()
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permissionPane)")!)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in stopPlayback() }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    private func newFileURL(appName: String) -> URL {
        let formatter = DateFormatter()
        // A fixed locale stops the Mac's 12-hour setting adding " pm" and an unusual space to file names.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = appName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = "\(safeName) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(name).wav")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(copy).wav")
            copy += 1
        }
        return url
    }

    private func show(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
            needsPermission = true
            permissionPane = "Privacy_ScreenCapture"
            message = "Audio Scratchpad needs permission to record audio. Allow it in System Settings, then reopen the app."
        } else {
            message = error.localizedDescription
        }
    }
}

// Loaded on first use, which is on a background thread, so reading the script never holds up the window.
private let sharedQualityChecker = Result { try QualityChecker() }

// The app's colours, which follow the Mac's light or dark appearance like the web version does.
extension Color {
    static let appBackground = adaptive(light: hex(0xFAF7F0), dark: hex(0x14120F))
    static let appText = adaptive(light: hex(0x1A1814), dark: hex(0xF3EEE3))
    static let appControl = adaptive(light: hex(0xECE6D8), dark: hex(0x2A261F))
    static let appMuted = adaptive(light: hex(0x6B655A), dark: hex(0xA39C8E))
    static let appRecord = adaptive(light: hex(0xE8321E), dark: hex(0xFF5A3C))
    static let highlight = Color(nsColor: hex(0xFFDF1F))
    static let highlightShadow = Color(nsColor: hex(0xB39400))
    static let onHighlight = Color(nsColor: hex(0x1A1814))

    private static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

extension Font {
    // Archivo Expanded ships inside the app, in a regular and a black weight.
    static func archivo(_ size: CGFloat, black: Bool = false) -> Font {
        .custom(black ? "ArchivoExpanded-Black" : "ArchivoExpanded-Regular", size: size)
    }
}

struct WaveformView: View {
    let peaks: [Float]
    var playhead: Double? = nil
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !peaks.isEmpty, size.width > 0 else { return }
                // Bars 2 points wide with a 1 point gap, each as tall as the loudest moment it covers.
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    let from = Int(x / size.width * CGFloat(peaks.count))
                    let to = min(peaks.count, max(from + 1, Int((x + 3) / size.width * CGFloat(peaks.count))))
                    let height = max(1, CGFloat(peaks[from..<to].max() ?? 0) * size.height).rounded()
                    path.addRect(CGRect(x: x, y: ((size.height - height) / 2).rounded(), width: 2, height: height))
                    x += 3
                }
                context.fill(path, with: .color(.appText))

                if let playhead {
                    let x = size.width * playhead
                    context.fill(Path(CGRect(x: x - 2, y: 0, width: 4, height: size.height)), with: .color(.appText))
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.highlight))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onSeek(drag.location.x / geometry.size.width)
            })
        }
    }
}

// Lays over a control so a click still acts on it, while dragging carries a file into another app.
// SwiftUI's own drag gesture never started inside the recordings list, so this handles the mouse through AppKit.
struct FileDragArea: NSViewRepresentable {
    let url: URL
    let onClick: () -> Void

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        view.toolTip = "Click to copy, or drag into another app"
        return view
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
        view.onClick = onClick
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var url: URL?
    var onClick: (() -> Void)?
    private var pressLocation: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        // A hand that shifts slightly during a click shouldn't turn it into a drag.
        guard let url, let pressLocation,
              hypot(event.locationInWindow.x - pressLocation.x, event.locationInWindow.y - pressLocation.y) > 3
        else { return }
        self.pressLocation = nil

        let size: CGFloat = 32
        let pointer = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: pointer.x - size / 2, y: pointer.y - size / 2, width: size, height: size),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pressLocation != nil { onClick?() }
        pressLocation = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// One on/off value for a view. An object rather than @State, which doesn't compile with only the command line tools installed.
final class Flag: ObservableObject {
    @Published var isOn = false
}

// Turns highlighter yellow under the pointer, like the web version's buttons and menu.
struct HoverHighlight: ViewModifier {
    var selected = false
    @StateObject private var hover = Flag()

    func body(content: Content) -> some View {
        content
            .foregroundStyle(hover.isOn ? Color.onHighlight : Color.appText)
            .background(hover.isOn ? Color.highlight : selected ? Color.appControl : Color.clear)
            .contentShape(Rectangle())
            .onHover { hover.isOn = $0 }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .frame(width: 32, height: 32)
            .modifier(HoverHighlight())
    }
}

// A yellow key with a hard shadow that it presses down into.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.archivo(14, black: true))
            .textCase(.uppercase)
            .foregroundStyle(isEnabled ? Color.onHighlight : Color.appMuted)
            .padding(.horizontal, 18)
            .frame(minWidth: 120, minHeight: 42)
            .background(isEnabled ? Color.highlight : Color.clear)
            .overlay(Rectangle().strokeBorder(isEnabled ? Color.highlight : Color.appMuted,
                                              style: StrokeStyle(lineWidth: 2, dash: isEnabled ? [] : [4, 3])))
            .background(Rectangle().fill(Color.appBackground).padding(-2))
            .background(Rectangle().fill(Color.highlightShadow).offset(x: pressed ? 0 : 5, y: pressed ? 0 : 5).opacity(isEnabled ? 1 : 0))
            .offset(x: pressed ? 5 : 0, y: pressed ? 5 : 0)
    }
}

// Stands in for the quality label until the check finishes, stepping along like the web version's.
struct LoadingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 5) % 6
            Rectangle()
                .fill(Color.appText)
                .frame(width: reduceMotion ? 40 : 16)
                .opacity(reduceMotion ? 0.5 : 1)
                .offset(x: reduceMotion ? 0 : CGFloat(step) * 8 - 16)
                .frame(width: 40, height: 2, alignment: .leading)
                .clipped()
        }
        .padding(2)
        .overlay(Rectangle().strokeBorder(Color.appText, lineWidth: 2))
        .frame(width: 44, height: 6)
    }
}

// Whether a recording is lossless, lossy or upsampled, with a note on hover, and a loading bar until that's known.
// Always the same width, so the waveforms in every row line up.
struct QualityLabel: View {
    let report: QualityReport?
    var isLoading = false
    @StateObject private var tooltip = Flag()

    var body: some View {
        Group {
            if isLoading && report == nil {
                LoadingBar().accessibilityLabel("Checking quality")
            } else {
                label
            }
        }
        .frame(width: 116, alignment: .trailing)
    }

    private var label: some View {
        let text = report?.label ?? ""
        // Only labels that admit something was lost get the highlight.
        let lost = !text.isEmpty && text != "Lossless"
        return Text(text)
            .font(.archivo(11))
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, lost ? 4 : 0)
            .padding(.vertical, 1)
            .foregroundStyle(lost ? Color.onHighlight : Color.appText)
            .background(lost ? Color.highlight : Color.clear)
            .contentShape(Rectangle())
            // A popover, because SwiftUI's .help only appears after a delay.
            .onHover { tooltip.isOn = $0 && !(report?.tooltip.isEmpty ?? true) }
            .popover(isPresented: $tooltip.isOn, arrowEdge: .top) {
                Text(report?.tooltip ?? "")
                    .font(.archivo(12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .leading)
                    .padding(8)
            }
            .accessibilityLabel(report.map { "Quality: \($0.label). \($0.tooltip)" } ?? "")
            .accessibilityHidden(text.isEmpty)
    }
}

// Shows keyboard focus as a square outline in the app's text colour, in place of the Mac's blue ring.
struct FocusRing: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay(Rectangle().strokeBorder(Color.appText, lineWidth: 2).padding(-4).opacity(isFocused ? 1 : 0))
    }
}

struct RowSeparator: View {
    var body: some View {
        Rectangle().fill(Color.appText).frame(height: 1)
    }
}

struct LiveRecordingRow: View {
    @ObservedObject var live: LiveWaveform
    let name: String
    let startedAt: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 12))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.appRecord)
                .accessibilityLabel("Recording")

            WaveformView(peaks: live.bars)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help(name)
                .accessibilityElement()
                .accessibilityLabel(name)

            // Blank, to line the waveform up with the finished rows below.
            QualityLabel(report: nil)

            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .font(.archivo(11))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)

            Color.clear.frame(width: 104, height: 32)
        }
        .padding(.vertical, 6)
    }
}

// Where the source button sits, so its menu can open just below it, over the recordings.
struct SourceButtonBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sourceMenu = Flag()
    @FocusState private var focusedControl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Audio Scratchpad")
                .font(.archivo(15, black: true))
                .textCase(.uppercase)
                .foregroundStyle(Color.appBackground)
                .padding(.horizontal, 30)
                // Archivo leaves extra room above capitals, so less padding on top centres them.
                .padding(.top, 2.25)
                .padding(.bottom, 5.75)
                .background(Color.appText)
                // Sits beside the window's close, minimise and zoom buttons, in place of the usual title.
                .padding(.leading, 78)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)

            controls
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .zIndex(1)

            if let message = model.message {
                HStack {
                    Text(message)
                    Spacer()
                    if model.needsPermission {
                        Button("Open Settings") { model.openPermissionSettings() }
                            .buttonStyle(.plain)
                            .font(.archivo(14, black: true))
                            .underline()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(Rectangle().strokeBorder(Color.appText, lineWidth: 2))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            RowSeparator()
                .padding(.horizontal, 16)
                .padding(.top, 20)

            if model.recordings.isEmpty && !model.isRecording {
                Text("No recordings yet")
                    .font(.archivo(14, black: true))
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let startedAt = model.startedAt, let url = model.currentURL {
                            LiveRecordingRow(live: model.live,
                                             name: url.deletingPathExtension().lastPathComponent,
                                             startedAt: startedAt)
                            if !model.recordings.isEmpty { RowSeparator() }
                        }
                        ForEach(model.recordings) { recording in
                            row(for: recording)
                            if recording.id != model.recordings.last?.id { RowSeparator() }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .font(.archivo(14))
        .foregroundStyle(Color.appText)
        .frame(minWidth: 480, minHeight: 340, alignment: .topLeading)
        .background(Color.appBackground)
        .ignoresSafeArea(.container, edges: .top)
        .overlayPreferenceValue(SourceButtonBounds.self) { anchor in
            if sourceMenu.isOn, let anchor {
                GeometryReader { geometry in
                    let box = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        // Clicking anywhere else closes the menu, as with a normal one.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { sourceMenu.isOn = false }
                        sourceMenuList
                            .frame(width: box.width)
                            .offset(x: box.minX, y: box.maxY - 1)
                    }
                }
            }
        }
        .onAppear {
            model.refreshSources()
            model.refreshRecordings()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshSources()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRecordings()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("Source")
                .font(.archivo(14, black: true))
                .textCase(.uppercase)
                .accessibilityHidden(true)

            sourceButton

            if let startedAt = model.startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.archivo(14, black: true))
                    .monospacedDigit()
                    .foregroundStyle(Color.onHighlight)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.highlight)
            }

            Button {
                Task {
                    if model.isCapturing {
                        await model.stop()
                    } else {
                        await model.start()
                    }
                }
            } label: {
                Label(model.isWaitingForAudio ? "waiting for audio..." : model.isRecording ? "Stop" : "Record",
                      systemImage: model.isCapturing ? "stop.fill" : "record.circle")
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(model.selectedSource == nil || model.isStarting || model.isStopping)
            .modifier(FocusRing(isFocused: focusedControl == "record"))
            .focused($focusedControl, equals: "record")
        }
    }

    // A button that opens a list of sources drawn to match the app, which a standard Mac menu can't be.
    private var sourceButton: some View {
        let source = model.sources.first { $0.id == model.selectedSource }
        return Button {
            if !sourceMenu.isOn { model.refreshSources() }
            sourceMenu.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                if let source { Image(nsImage: source.icon) }
                Text(source?.name ?? "Choose a source…")
                    .textCase(.uppercase)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .heavy))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
            .overlay(Rectangle().strokeBorder(Color.appText, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isCapturing)
        .opacity(model.isCapturing ? 0.5 : 1)
        .modifier(FocusRing(isFocused: focusedControl == "source"))
        .focused($focusedControl, equals: "source")
        .anchorPreference(key: SourceButtonBounds.self, value: .bounds) { $0 }
        .accessibilityLabel("Source")
        .accessibilityValue(source?.name ?? "None chosen")
    }

    private var sourceMenuList: some View {
        let options = VStack(spacing: 0) {
            ForEach(model.sources) { source in
                Button {
                    model.selectedSource = source.id
                    sourceMenu.isOn = false
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: source.icon)
                        Text(source.name).textCase(.uppercase).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .modifier(HoverHighlight(selected: source.id == model.selectedSource))
                }
                .buttonStyle(.plain)
            }
        }
        // Scrolls only when there are too many apps open to fit.
        return ViewThatFits(in: .vertical) {
            options
            ScrollView { options }
        }
        .frame(maxHeight: 280)
        .background(Color.appBackground)
        .overlay(Rectangle().strokeBorder(Color.appText, lineWidth: 1))
        .background(Rectangle().fill(Color.appText).offset(x: 3, y: 3))
    }

    private func row(for recording: Recording) -> some View {
        HStack(spacing: 4) {
            Button {
                model.togglePlayback(recording)
            } label: {
                Image(systemName: model.playingURL == recording.url ? "stop.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(model.playingURL == recording.url ? "Stop playing" : "Play")

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.playingURL != recording.url)) { _ in
                WaveformView(
                    peaks: model.waveforms[recording.url] ?? [],
                    playhead: model.playingURL == recording.url ? model.playbackProgress : nil,
                    onSeek: { model.seek(recording, to: $0) }
                )
            }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help(recording.name)
                .accessibilityElement()
                .accessibilityLabel(recording.name)
                .task(id: recording.url) { await model.loadWaveform(for: recording.url) }

            QualityLabel(report: model.qualities[recording.url], isLoading: true)
                .task(id: recording.url) { await model.loadQuality(for: recording.url) }

            Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.archivo(11))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)

            Button { model.copyToClipboard(recording) } label: {
                Image(systemName: model.copiedURL == recording.url ? "checkmark" : "doc.on.doc")
            }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(model.copiedURL == recording.url ? "Copied" : "Copy to clipboard")
                .overlay(FileDragArea(url: recording.url) { model.copyToClipboard(recording) })
            Button { model.reveal(recording) } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Show in Finder")
            Button { model.moveToTrash(recording) } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Move to Trash")
        }
        .padding(.vertical, 6)
    }
}

// Holds the quit until recording has stopped, so the last moments of audio still reach the file.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isCapturing else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AudioScratchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Audio Scratchpad", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
