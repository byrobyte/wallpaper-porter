import AppKit
import AVFoundation
import WebKit

/// Plays a video or web wallpaper in borderless windows that sit at desktop level, behind your icons.
@MainActor
final class LiveWallpaper: ObservableObject {
    static let shared = LiveWallpaper()

    @Published private(set) var currentItemID: String?
    @Published private(set) var paused = false

    private var item: LibraryItem?
    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var webViews: [WKWebView] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let savedKey = "liveWallpaperFolder"

    private init() {
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        observe(nc, NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        observe(wnc, NSWorkspace.screensDidSleepNotification) { $0.suspend() }
        observe(wnc, NSWorkspace.willSleepNotification) { $0.suspend() }
        observe(wnc, NSWorkspace.screensDidWakeNotification) { $0.resumeIfNeeded() }
        observe(wnc, NSWorkspace.didWakeNotification) { $0.resumeIfNeeded() }
        observe(wnc, NSWorkspace.activeSpaceDidChangeNotification) { me in
            me.windows.forEach { $0.orderFrontRegardless() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (LiveWallpaper) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }

    // MARK: Public

    func start(_ item: LibraryItem) {
        stop(clearSaved: false)
        self.item = item
        currentItemID = item.id
        paused = false
        UserDefaults.standard.set(item.folder.path, forKey: savedKey)
        // Matching still underneath so Mission Control / lock screen look right.
        if let still = item.mainURL { try? Desktop.setStill(still) }
        rebuild()
    }

    func stop(clearSaved: Bool = true) {
        tearDown()
        item = nil
        currentItemID = nil
        paused = false
        if clearSaved { UserDefaults.standard.removeObject(forKey: savedKey) }
    }

    func togglePause() {
        paused.toggle()
        paused ? suspend() : resumeIfNeeded()
    }

    /// Called at launch to bring back the last live wallpaper.
    func restore() {
        guard let path = UserDefaults.standard.string(forKey: savedKey),
              let item = LibraryItem.load(from: URL(fileURLWithPath: path, isDirectory: true)),
              item.isLiveCapable else { return }
        start(item)
    }

    // MARK: Internals

    private func tearDown() {
        player?.pause()
        looper = nil
        player = nil
        webViews.forEach { $0.loadHTMLString("", baseURL: nil) }
        webViews.removeAll()
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
    }

    private func rebuild() {
        guard let item else { return }
        tearDown()

        if let videoURL = item.url(item.video), FileManager.default.fileExists(atPath: videoURL.path) {
            let template = AVPlayerItem(url: videoURL)
            let p = AVQueuePlayer()
            p.isMuted = true
            p.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: p, templateItem: template)
            player = p
            for screen in NSScreen.screens {
                let w = makeWindow(screen)
                w.contentView = PlayerView(player: p)
                show(w)
            }
            if !paused { p.play() }
        } else if let entry = item.url(item.web), FileManager.default.fileExists(atPath: entry.path) {
            let root = item.folder.appendingPathComponent("web", isDirectory: true)
            let script = Self.wallpaperEngineShim(projectFolder: root)
            for screen in NSScreen.screens {
                let w = makeWindow(screen)
                let config = WKWebViewConfiguration()
                config.mediaTypesRequiringUserActionForPlayback = []
                config.userContentController.addUserScript(
                    WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                let web = WKWebView(frame: w.contentLayoutRect, configuration: config)
                web.setValue(false, forKey: "drawsBackground")
                web.loadFileURL(entry, allowingReadAccessTo: root)
                w.contentView = web
                webViews.append(web)
                show(w)
            }
        }
    }

    private func makeWindow(_ screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        return w
    }

    private func show(_ w: NSWindow) {
        w.orderFrontRegardless()
        windows.append(w)
    }

    private func suspend() {
        player?.pause()
    }

    private func resumeIfNeeded() {
        guard !paused else { return }
        player?.play()
    }

    /// Minimal stand-ins for Wallpaper Engine's JavaScript hooks, plus the wallpaper's default settings.
    private static func wallpaperEngineShim(projectFolder: URL) -> String {
        var propsJSON = "{}"
        if let project = Converter.json(projectFolder.appendingPathComponent("project.json")),
           let general = project["general"] as? [String: Any],
           let props = general["properties"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: props),
           let s = String(data: d, encoding: .utf8) {
            propsJSON = s
        }
        return """
        (function(){
          var noop = function(){};
          window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || noop;
          window.wallpaperRegisterMediaStatusListener = window.wallpaperRegisterMediaStatusListener || noop;
          window.wallpaperRegisterMediaPropertiesListener = window.wallpaperRegisterMediaPropertiesListener || noop;
          window.wallpaperRegisterMediaThumbnailListener = window.wallpaperRegisterMediaThumbnailListener || noop;
          window.wallpaperRegisterMediaPlaybackListener = window.wallpaperRegisterMediaPlaybackListener || noop;
          window.wallpaperRegisterMediaTimelineListener = window.wallpaperRegisterMediaTimelineListener || noop;
          var props = \(propsJSON);
          window.addEventListener('load', function(){
            try {
              var l = window.wallpaperPropertyListener;
              if (l && l.applyGeneralProperties) l.applyGeneralProperties({ fps: 30 });
              if (l && l.applyUserProperties) l.applyUserProperties(props);
              if (l && l.setPaused) l.setPaused(false);
            } catch (e) { console.log(e); }
          });
        })();
        """
    }
}

/// Layer-backed view showing an AVPlayer, filling the screen.
final class PlayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
}
