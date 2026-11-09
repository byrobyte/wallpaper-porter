import Foundation
import AppKit

let wallpaperEngineAppID = "431960"

struct WorkshopInfo {
    var title: String
    var appID: Int?
}

enum WorkshopAPI {
    /// Accepts a full Workshop URL, a steam:// link, or a bare item ID.
    static func parseIDs(from text: String) -> [String] {
        var ids: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            if let id = parseID(String(token)), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    static func parseID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t.allSatisfy(\.isNumber) { return t }
        if let c = URLComponents(string: t), let id = c.queryItems?.first(where: { $0.name == "id" })?.value,
           !id.isEmpty, id.allSatisfy(\.isNumber) {
            return id
        }
        if t.contains("steam"), let r = t.range(of: #"\d{6,}"#, options: .regularExpression) {
            return String(t[r])
        }
        return nil
    }

    /// Public Steam API, no key needed. Used for the title and to check it's a Wallpaper Engine item.
    static func details(for id: String) async throws -> WorkshopInfo {
        var req = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = json["response"] as? [String: Any],
              let d = (resp["publishedfiledetails"] as? [[String: Any]])?.first,
              (d["result"] as? Int) == 1 else {
            throw PorterError.message("Steam couldn't find Workshop item \(id) (it may be private or removed).")
        }
        return WorkshopInfo(title: (d["title"] as? String) ?? "Wallpaper \(id)",
                            appID: d["consumer_app_id"] as? Int)
    }
}

/// Wraps Valve's SteamCMD, which downloads Workshop items for games you own.
final class SteamCMD {
    static let shared = SteamCMD()

    let root: URL
    var script: URL { root.appendingPathComponent("steamcmd.sh") }
    var downloadDir: URL { root.appendingPathComponent("downloads") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: script.path) }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Wallpaper Porter/steamcmd", isDirectory: true)
    }

    static func isValidUsername(_ u: String) -> Bool {
        !u.isEmpty && u.count <= 64 && u.range(of: #"^[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil
    }

    func install() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PorterError.message("Download of SteamCMD failed (HTTP \(http.statusCode)).")
        }
        let archive = root.appendingPathComponent("steamcmd_osx.tar.gz")
        try? fm.removeItem(at: archive)
        try fm.moveItem(at: tmp, to: archive)
        let status = try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", root.path])
        try? fm.removeItem(at: archive)
        guard status == 0, isInstalled else { throw PorterError.message("Couldn't unpack SteamCMD.") }
    }

    /// Opens Terminal so the user can type their password and Steam Guard code once.
    /// SteamCMD caches the login, so later downloads run without a password.
    func openSignInTerminal(username: String) throws {
        guard Self.isValidUsername(username) else { throw PorterError.message("That doesn't look like a Steam username.") }
        let cmd = root.appendingPathComponent("Sign in to Steam.command")
        let body = """
        #!/bin/bash
        cd "$(dirname "$0")"
        clear
        echo "Wallpaper Porter — Steam sign-in"
        echo "================================="
        if [ "$(uname -m)" = "arm64" ] && ! /usr/bin/pgrep -q oahd; then
          echo "SteamCMD needs Rosetta on Apple Silicon. Installing it (you may be asked for your Mac password)…"
          /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        fi
        echo
        echo "Signing in as \(username). Type your Steam password and Steam Guard code when asked."
        echo "(The first run also updates SteamCMD, which takes a minute.)"
        echo
        ./steamcmd.sh +login "\(username)" +quit
        echo
        echo "Done. Close this window and go back to Wallpaper Porter."
        read -n 1 -s -r -p "Press any key to close…"

        """
        try body.write(to: cmd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmd.path)
        NSWorkspace.shared.open(cmd)
    }

    struct NeedsSignIn: LocalizedError {
        var errorDescription: String? { "Steam needs you to sign in again. Use “Sign in to Steam…” in Steam setup, then retry." }
    }

    /// Downloads a Wallpaper Engine Workshop item and returns its folder.
    func download(id: String, username: String, log: @escaping (String) -> Void) async throws -> URL {
        guard Self.isValidUsername(username) else { throw PorterError.message("Set your Steam username in Steam setup first.") }
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let args = [script.path,
                    "+@sSteamCmdForcePlatformType", "windows",
                    "+force_install_dir", downloadDir.path,
                    "+login", username,
                    "+workshop_download_item", wallpaperEngineAppID, id, "validate",
                    "+quit"]

        var reportedPath: String?
        var lastError: String?
        var askedForPassword = false

        let status = try await Shell.run("/bin/bash", args, cwd: root, timeout: 3600) { line, process in
            log(line)
            let lower = line.lowercased()
            if lower.contains("password:") || lower.contains("steam guard code") || lower.contains("two-factor") {
                askedForPassword = true
                process.terminate()
            }
            if let r = line.range(of: #"Downloaded item \d+ to "(.+)""#, options: .regularExpression) {
                let m = String(line[r])
                if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
                    reportedPath = String(m[m.index(after: q1) ..< q2])
                }
            }
            if line.contains("ERROR") || line.contains("FAILED") || lower.contains("failure") { lastError = line }
        }

        if askedForPassword { throw NeedsSignIn() }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let rel = "steamapps/workshop/content/\(wallpaperEngineAppID)/\(id)"
        var candidates: [URL] = []
        if let p = reportedPath { candidates.append(URL(fileURLWithPath: p)) }
        candidates += [downloadDir.appendingPathComponent(rel),
                       root.appendingPathComponent(rel),
                       home.appendingPathComponent("Library/Application Support/Steam/\(rel)"),
                       home.appendingPathComponent("Steam/\(rel)")]
        for c in candidates {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: c.path), !items.isEmpty { return c }
        }
        let reason = lastError.map { " SteamCMD said: \($0.trimmingCharacters(in: .whitespaces))" } ?? " (exit code \(status))"
        throw PorterError.message("Download failed. Make sure this Steam account owns Wallpaper Engine.\(reason)")
    }
}

/// Small helper to run a command and stream its output line by line.
enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 600,
                    onLine: ((String, Process) -> Void)? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            let lines = LineBuffer { line in onLine?(line, p) }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { lines.append(d) }
            }

            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            p.terminationHandler = { proc in
                timer.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                lines.append(rest)
                lines.finish()
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe line splitter for process output.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        // SteamCMD prints prompts like "password:" without a newline; surface them too.
        let tail = String(decoding: buffer.suffix(32), as: UTF8.self).lowercased()
        flush(final: tail.hasSuffix("password: ") || tail.hasSuffix("code: ") || tail.hasSuffix(":"))
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        flush(final: true)
    }

    private func flush(final: Bool) {
        while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex ..< nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ... nl)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
        }
        if final, !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
        }
    }
}
