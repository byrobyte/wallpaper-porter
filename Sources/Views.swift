import SwiftUI
import AppKit
import ServiceManagement

@main
@MainActor
struct WallpaperPorterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Wallpaper Porter", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 980, height: 720)

        MenuBarExtra("Wallpaper Porter", systemImage: "photo.on.rectangle.angled") {
            MenuContent().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in LiveWallpaper.shared.restore() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Menu bar

@MainActor
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live = LiveWallpaper.shared
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Button("Open Wallpaper Porter") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let id = live.currentItemID {
            Divider()
            Text("Live: " + (model.library.first { $0.id == id }?.title ?? "wallpaper"))
            Button(live.paused ? "Resume" : "Pause") { live.togglePause() }
            Button("Stop Live Wallpaper") { live.stop() }
        }
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { openAtLogin },
            set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { model.alert = "Couldn't change login item: \(error.localizedDescription). Try moving the app to Applications first." }
                openAtLogin = SMAppService.mainApp.status == .enabled
            }))
        Divider()
        Button("Quit Wallpaper Porter") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// MARK: - Main window

@MainActor
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live = LiveWallpaper.shared
    @State private var links = ""
    @State private var showSetup = false
    @State private var picking: LibraryItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.steamReady || showSetup { SetupCard(collapse: { showSetup = false }) }
                    importBar
                    if !model.jobs.isEmpty { JobsList() }
                    librarySection
                }
                .padding(20)
            }
        }
        .sheet(item: $picking) { item in ImagePicker(item: item) }
        .alert("Wallpaper Porter", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallpaper Porter").font(.title2.weight(.semibold))
                Text("Wallpaper Engine wallpapers on your Mac").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if live.currentItemID != nil {
                Label(live.paused ? "Live paused" : "Live wallpaper on", systemImage: live.paused ? "pause.circle" : "play.circle.fill")
                    .foregroundStyle(.secondary)
                Button(live.paused ? "Resume" : "Pause") { live.togglePause() }
                Button("Stop") { live.stop() }
            }
            if model.steamReady {
                Button { showSetup.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Steam setup")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var importBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add wallpapers").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                TextField("Paste Steam Workshop links (one or more)…", text: $links, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Import", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Import Folder…", action: pickFolder)
                    .help("Already have a downloaded Workshop folder (with project.json)? Import it directly.")
            }
            Text("Example: https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library").font(.headline)
                Text("\(model.library.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { model.openLibraryFolder() }.buttonStyle(.link)
            }
            if model.library.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Imported wallpapers appear here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(model.library) { item in
                        WallpaperCard(item: item, isLive: live.currentItemID == item.id, pick: { picking = item })
                    }
                }
            }
        }
    }

    private func submit() {
        let n = model.importLinks(links)
        if n == 0 { model.alert = "No Steam Workshop links found. Paste a link like steamcommunity.com/sharedfiles/filedetails/?id=…" }
        else { links = "" }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose Wallpaper Engine Workshop folder(s) — each contains a project.json"
        if panel.runModal() == .OK { panel.urls.forEach(model.importFolder) }
    }
}

// MARK: - Setup

@MainActor
struct SetupCard: View {
    @EnvironmentObject var model: AppModel
    var collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Steam setup").font(.headline)
                Spacer()
                if model.steamReady { Button("Done", action: collapse) }
            }
            Text("Wallpapers are downloaded with Valve's SteamCMD using your own Steam account, which must own Wallpaper Engine. Your password is typed into Steam's own sign-in in Terminal — this app never sees it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(1, done: model.steamcmdInstalled, title: "Install SteamCMD") {
                if model.installingSteamCMD { ProgressView().controlSize(.small) }
                else { Button(model.steamcmdInstalled ? "Reinstall" : "Install") { model.installSteamCMD() } }
            }
            step(2, done: SteamCMD.isValidUsername(model.steamUser), title: "Steam username") {
                TextField("Account name (not display name)", text: $model.steamUser)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
            }
            step(3, done: model.signedIn, title: "Sign in once (password + Steam Guard)") {
                Button("Sign in to Steam…") { model.signIn() }
                    .disabled(!model.steamcmdInstalled || !SteamCMD.isValidUsername(model.steamUser))
            }
            if model.signedIn {
                Text("Finish signing in inside the Terminal window that opened, then import links below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardFill))
    }

    private func step<C: View>(_ n: Int, done: Bool, title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            Text(title)
            Spacer()
            control()
        }
    }
}

// MARK: - Jobs

@MainActor
struct JobsList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Imports").font(.headline)
                Spacer()
                Button("Clear finished") { model.clearFinished() }.buttonStyle(.link)
            }
            ForEach(model.jobs) { job in
                HStack(alignment: .top, spacing: 10) {
                    icon(job.state).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).lineLimit(1)
                        Group {
                            switch job.state {
                            case .queued: Text("Waiting…")
                            case .working(let s): Text(job.lastLog.isEmpty ? s : "\(s)  \(job.lastLog)").lineLimit(1)
                            case .done: Text("Added to library")
                            case .failed(let e): Text(e).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .failed = job.state { Button("Retry") { model.retry(job) } }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardFill))
            }
        }
    }

    @ViewBuilder private func icon(_ s: Job.State) -> some View {
        switch s {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - Library card

@MainActor
struct WallpaperCard: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let isLive: Bool
    let pick: () -> Void
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Thumbnail(url: item.url(item.thumb) ?? item.mainURL)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 4) {
                    Badge(text: item.type.capitalized)
                    if isLive { Badge(text: "● Live", tint: .green) }
                }
                .padding(6)
            }
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1).help(item.title)
            HStack(spacing: 6) {
                if item.main != nil { Button("Set Wallpaper") { model.setStill(item) } }
                if item.isLiveCapable {
                    Button(isLive ? "Live ✓" : "Set Live") { model.setLive(item) }.disabled(isLive)
                }
                Spacer(minLength: 0)
                Menu {
                    if item.stills.count > 1 { Button("Choose Image…", action: pick) }
                    Button("Show in Finder") { model.reveal(item) }
                    if let notes = item.notes, !notes.isEmpty { Button("Conversion Notes…") { showNotes = true } }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.delete(item) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isLive ? Color.green.opacity(0.6) : .clear, lineWidth: 2))
        .popover(isPresented: $showNotes) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.notes ?? [], id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
            }
            .padding().frame(width: 320)
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .black
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.6)))
    }
}

@MainActor
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

// MARK: - Image picker for scenes

@MainActor
struct ImagePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an image from “\(item.title)”").font(.headline)
            Text("Scenes are made of layers. Pick the one to use as your wallpaper.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(item.stills, id: \.self) { rel in
                        Button {
                            model.chooseMain(item, rel: rel)
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                Thumbnail(url: item.url(rel)).aspectRatio(16 / 10, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(rel == item.main ? Color.accentColor : .clear, lineWidth: 3))
                                Text((rel as NSString).lastPathComponent).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}

extension Color {
    static let cardFill = Color(nsColor: .controlBackgroundColor)
}
