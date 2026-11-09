import Foundation
import AppKit

struct Job: Identifiable, Equatable {
    enum Source: Equatable { case workshop(String), folder(URL) }
    enum State: Equatable { case queued, working(String), done, failed(String) }

    let id = UUID()
    var source: Source
    var title: String
    var state: State = .queued
    var lastLog: String = ""
}

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var library: [LibraryItem] = []
    @Published var steamcmdInstalled = SteamCMD.shared.isInstalled
    @Published var installingSteamCMD = false
    @Published var alert: String?
    @Published var steamUser: String = UserDefaults.standard.string(forKey: "steamUser") ?? "" {
        didSet { UserDefaults.standard.set(steamUser, forKey: "steamUser") }
    }
    @Published var signedIn: Bool = UserDefaults.standard.bool(forKey: "steamSignedIn") {
        didSet { UserDefaults.standard.set(signedIn, forKey: "steamSignedIn") }
    }

    var steamReady: Bool { steamcmdInstalled && SteamCMD.isValidUsername(steamUser) && signedIn }

    let outputRoot: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wallpaper Engine for Mac", isDirectory: true)

    private var queueRunning = false

    init() { reloadLibrary() }

    // MARK: Library

    func reloadLibrary() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        let dated = dirs.compactMap { dir -> (LibraryItem, Date)? in
            guard let item = LibraryItem.load(from: dir) else { return nil }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (item, date)
        }
        library = dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func setStill(_ item: LibraryItem, image: URL? = nil) {
        guard let url = image ?? item.mainURL else {
            alert = "This wallpaper has no still image. Try “Set Live” instead."
            return
        }
        LiveWallpaper.shared.stop()
        do { try Desktop.setStill(url) } catch { alert = "Couldn't set the wallpaper: \(error.localizedDescription)" }
    }

    func chooseMain(_ item: LibraryItem, rel: String) {
        var it = item
        it.main = rel
        if let u = it.mainURL, Converter.writeThumbnail(from: u, to: it.folder.appendingPathComponent("thumb.jpg")) {
            it.thumb = "thumb.jpg"
        }
        try? it.save()
        reloadLibrary()
        setStill(it)
    }

    func setLive(_ item: LibraryItem) {
        LiveWallpaper.shared.start(item)
    }

    func reveal(_ item: LibraryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.mainURL ?? item.folder])
    }

    func delete(_ item: LibraryItem) {
        if LiveWallpaper.shared.currentItemID == item.id { LiveWallpaper.shared.stop() }
        try? FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
        reloadLibrary()
    }

    func openLibraryFolder() {
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputRoot)
    }

    // MARK: Steam setup

    func installSteamCMD() {
        installingSteamCMD = true
        Task {
            do { try await SteamCMD.shared.install() } catch { alert = error.localizedDescription }
            steamcmdInstalled = SteamCMD.shared.isInstalled
            installingSteamCMD = false
        }
    }

    func signIn() {
        do {
            try SteamCMD.shared.openSignInTerminal(username: steamUser.trimmingCharacters(in: .whitespaces))
            signedIn = true
        } catch { alert = error.localizedDescription }
    }

    // MARK: Importing

    /// Returns how many links were recognised.
    @discardableResult
    func importLinks(_ text: String) -> Int {
        let ids = WorkshopAPI.parseIDs(from: text)
        for id in ids where !jobs.contains(where: { $0.source == .workshop(id) && !isFinished($0) }) {
            jobs.append(Job(source: .workshop(id), title: "Workshop item \(id)"))
        }
        runQueue()
        return ids.count
    }

    func importFolder(_ url: URL) {
        jobs.append(Job(source: .folder(url), title: url.lastPathComponent))
        runQueue()
    }

    func retry(_ job: Job) {
        update(job.id) { $0.state = .queued; $0.lastLog = "" }
        runQueue()
    }

    func clearFinished() { jobs.removeAll(where: isFinished) }

    private func isFinished(_ j: Job) -> Bool {
        switch j.state { case .done, .failed: return true; default: return false }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    private func runQueue() {
        guard !queueRunning else { return }
        queueRunning = true
        Task {
            while let job = jobs.first(where: { $0.state == .queued }) {
                await process(job)
            }
            queueRunning = false
        }
    }

    private func process(_ job: Job) async {
        let jid = job.id
        let outputRoot = self.outputRoot
        do {
            let folder: URL
            let itemID: String
            var title: String? = nil

            switch job.source {
            case .folder(let url):
                folder = url
                let name = url.lastPathComponent
                itemID = name.allSatisfy(\.isNumber) && !name.isEmpty ? name : "local-" + String(UUID().uuidString.prefix(8))

            case .workshop(let wid):
                itemID = wid
                update(jid) { $0.state = .working("Looking up on Steam…") }
                if let info = try? await WorkshopAPI.details(for: wid) {
                    title = info.title
                    update(jid) { $0.title = info.title }
                    if let app = info.appID, String(app) != wallpaperEngineAppID {
                        throw PorterError.message("This Workshop item isn't a Wallpaper Engine wallpaper.")
                    }
                }
                guard steamReady else {
                    throw PorterError.message("Finish Steam setup (top of the window), then press Retry.")
                }
                update(jid) { $0.state = .working("Downloading with SteamCMD…") }
                let user = steamUser
                do {
                    folder = try await SteamCMD.shared.download(id: wid, username: user) { [weak self] line in
                        Task { @MainActor in self?.update(jid) { $0.lastLog = line } }
                    }
                } catch is SteamCMD.NeedsSignIn {
                    signedIn = false
                    throw SteamCMD.NeedsSignIn()
                }
            }

            update(jid) { $0.state = .working("Converting…") }
            let fallback = title
            _ = try await Task.detached(priority: .userInitiated) {
                try Converter.convert(folder: folder, id: itemID, fallbackTitle: fallback, outputRoot: outputRoot)
            }.value
            update(jid) { $0.state = .done }
            reloadLibrary()
        } catch {
            update(jid) { $0.state = .failed(error.localizedDescription) }
        }
    }
}
