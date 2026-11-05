// A small Mac app that records the sound of one chosen app to .wav files and lists them.
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
    let id: String
    let name: String
    let icon: NSImage

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
    @Published var playingURL: URL?
    @Published var waveforms: [URL: [Float]] = [:]
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
        sources = NSWorkspace.shared.runningApplications
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

    func start() async {
        guard let source = sources.first(where: { $0.id == selectedSource }), !isStarting, !isStopping, !isCapturing else { return }
        isStarting = true
        defer { isStarting = false }
        message = nil
        needsPermission = false
        stopPlayback()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first,
                  let app = content.applications.first(where: { $0.bundleIdentifier == source.id })
            else {
                message = "\(source.name) isn't available to record. Is it still open?"
                return
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
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
            try await recorder.start(filter: filter, url: url)
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
            message = "No sound came from that app, so nothing was saved."
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
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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
            message = "Audio Scratchpad needs permission to record audio. Allow it in System Settings, then reopen the app."
        } else {
            message = error.localizedDescription
        }
    }
}

extension Color {
    static let appAccent = Color(red: 0.78, green: 0.89, blue: 1.0)
}

struct WaveformView: View {
    let peaks: [Float]
    var playhead: Double? = nil
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                var path = Path()
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * size.height)
                    path.addRect(CGRect(x: CGFloat(index) * barWidth, y: (size.height - height) / 2,
                                        width: barWidth, height: height))
                }
                context.fill(path, with: .color(.appAccent))

                if let playhead {
                    let line = CGRect(x: size.width * playhead - 1, y: 0, width: 2, height: size.height)
                    context.fill(Path(line), with: .color(.primary))
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

struct LiveRecordingRow: View {
    @ObservedObject var live: LiveWaveform
    let name: String
    let startedAt: Date

    var body: some View {
        HStack {
            Image(systemName: "record.circle.fill")
                .frame(width: 18)
                .foregroundStyle(.red)
                .accessibilityLabel("Recording")

            WaveformView(peaks: live.bars)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help(name)
                .accessibilityElement()
                .accessibilityLabel(name)

            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Invisible, to line the waveform up with the finished rows below.
            Image(systemName: "doc.on.doc").hidden()
            Image(systemName: "folder").hidden()
            Image(systemName: "trash").hidden()
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            controls.padding()
            if let message = model.message {
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    Spacer()
                    if model.needsPermission {
                        Button("Open Settings") { model.openPermissionSettings() }
                    }
                }
                .padding([.horizontal, .bottom])
            }
            Divider()
            if model.recordings.isEmpty && !model.isRecording {
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let startedAt = model.startedAt, let url = model.currentURL {
                        LiveRecordingRow(live: model.live,
                                         name: url.deletingPathExtension().lastPathComponent,
                                         startedAt: startedAt)
                    }
                    ForEach(model.recordings) { row(for: $0) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 340)
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
        HStack {
            Picker("Source", selection: $model.selectedSource) {
                Text("Choose an app…").tag(String?.none)
                ForEach(model.sources) { source in
                    Label { Text(source.name) } icon: { Image(nsImage: source.icon) }
                        .tag(Optional(source.id))
                }
            }
            .disabled(model.isCapturing)

            if let startedAt = model.startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .foregroundStyle(.red)
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
                    .frame(minWidth: 70)
            }
            .controlSize(.large)
            .disabled(model.selectedSource == nil || model.isStarting || model.isStopping)
        }
    }

    private func row(for recording: Recording) -> some View {
        HStack {
            Button {
                model.togglePlayback(recording)
            } label: {
                Image(systemName: model.playingURL == recording.url ? "stop.fill" : "play.fill")
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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

            Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button { model.copyToClipboard(recording) } label: {
                Image(systemName: model.copiedURL == recording.url ? "checkmark" : "doc.on.doc")
            }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.copiedURL == recording.url ? "Copied" : "Copy to clipboard")
                .overlay(FileDragArea(url: recording.url) { model.copyToClipboard(recording) })
            Button { model.reveal(recording) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show in Finder")
            Button { model.moveToTrash(recording) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Move to Trash")
        }
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
                .tint(.appAccent)
                .onAppear { delegate.model = model }
        }
    }
}
