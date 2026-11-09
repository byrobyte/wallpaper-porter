import Foundation
import AppKit
import AVFoundation
import ImageIO

/// One converted wallpaper in the library. Saved as `porter.json` inside its folder.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var type: String            // video | scene | web | other
    var video: String?          // relative path of a playable video
    var web: String?            // relative path of the web wallpaper's HTML entry point
    var stills: [String]        // relative paths of images usable as a normal wallpaper
    var main: String?           // the still used by "Set as Wallpaper"
    var thumb: String?
    var notes: [String]?
    var folder: URL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey { case id, title, type, video, web, stills, main, thumb, notes }

    func url(_ rel: String?) -> URL? { rel.map { folder.appendingPathComponent($0) } }
    var isLiveCapable: Bool { video != nil || web != nil }
    var mainURL: URL? { url(main) }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: folder.appendingPathComponent("porter.json"))
    }

    static func load(from folder: URL) -> LibraryItem? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("porter.json")),
              var item = try? JSONDecoder().decode(LibraryItem.self, from: d) else { return nil }
        item.folder = folder
        return item
    }
}

enum Converter {
    static let playableVideo: Set<String> = ["mp4", "m4v", "mov"]
    static let stillImage: Set<String> = ["jpg", "jpeg", "png", "heic", "bmp", "tif", "tiff", "webp"]

    static func convert(folder src: URL, id: String, fallbackTitle: String?, outputRoot: URL) throws -> LibraryItem {
        let fm = FileManager.default
        let project = json(src.appendingPathComponent("project.json")) ?? [:]

        var title = (project["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = fallbackTitle ?? "Wallpaper \(id)" }
        let file = project["file"] as? String
        var type = (project["type"] as? String ?? "").lowercased()
        if type.isEmpty {
            if fm.fileExists(atPath: src.appendingPathComponent("scene.pkg").path)
                || fm.fileExists(atPath: src.appendingPathComponent("scene.json").path) { type = "scene" }
            else if let f = file, playableVideo.contains((f as NSString).pathExtension.lowercased()) { type = "video" }
            else if let f = file, f.lowercased().hasSuffix(".html") { type = "web" }
            else { type = "other" }
        }

        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let out = outputRoot.appendingPathComponent("\(safeName(title)) [\(id)]", isDirectory: true)
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var item = LibraryItem(id: id, title: title, type: type, stills: [])
        item.folder = out
        var notes: [String] = []

        // Steam preview image (jpg/png/gif)
        var previewRel: String?
        if let p = project["preview"] as? String, let rel = PKG.safeRelativePath(p) {
            let s = src.appendingPathComponent(rel)
            if fm.fileExists(atPath: s.path) {
                let name = "preview." + s.pathExtension.lowercased()
                try? fm.copyItem(at: s, to: out.appendingPathComponent(name))
                previewRel = name
            }
        }

        switch type {
        case "video":
            guard let f = file, let rel = PKG.safeRelativePath(f), fm.fileExists(atPath: src.appendingPathComponent(rel).path) else {
                throw PorterError.message("The video file listed in project.json is missing.")
            }
            let ext = (rel as NSString).pathExtension.lowercased()
            let name = "video.\(ext)"
            try fm.copyItem(at: src.appendingPathComponent(rel), to: out.appendingPathComponent(name))
            if playableVideo.contains(ext) {
                item.video = name
                if let frame = try? videoFrame(out.appendingPathComponent(name)) {
                    try writePNG(frame, to: out.appendingPathComponent("still.png"))
                    item.stills.append("still.png")
                    item.main = "still.png"
                }
            } else {
                notes.append("This wallpaper's video is .\(ext), which macOS can't play. The file was kept; convert it to MP4 (e.g. with HandBrake) to use it live.")
            }

        case "scene":
            try convertScene(src: src, out: out, item: &item, notes: &notes)

        case "web":
            let webDir = out.appendingPathComponent("web", isDirectory: true)
            try fm.copyItem(at: src, to: webDir)
            let entry = PKG.safeRelativePath(file ?? "index.html") ?? "index.html"
            if fm.fileExists(atPath: webDir.appendingPathComponent(entry).path) {
                item.web = "web/" + entry
            } else {
                notes.append("Couldn't find the page \(entry) for this web wallpaper.")
            }
            notes.append("Web wallpapers run live. Some rely on Wallpaper Engine features (audio visualisers, settings) that won't work on Mac.")

        default:
            notes.append("“\(type)” wallpapers are Windows programs and can't run on a Mac, so only the preview image was saved.")
        }

        // Fall back to the preview image when there's nothing better.
        if item.main == nil, let p = previewRel, stillImage.contains((p as NSString).pathExtension.lowercased()) {
            item.stills.append(p)
            item.main = p
            if type == "scene" { notes.append("Used Steam's preview image as the wallpaper.") }
        }
        if item.main == nil, let p = previewRel, p.hasSuffix(".gif"),
           let img = NSImage(contentsOf: out.appendingPathComponent(p)),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try? writePNG(cg, to: out.appendingPathComponent("preview-frame.png"))
            item.stills.append("preview-frame.png")
            item.main = "preview-frame.png"
        }

        guard item.main != nil || item.video != nil || item.web != nil else {
            try? fm.removeItem(at: out)
            throw PorterError.message("Nothing in this wallpaper could be converted for macOS.")
        }

        if let source = item.mainURL ?? previewRel.map({ out.appendingPathComponent($0) }) {
            if writeThumbnail(from: source, to: out.appendingPathComponent("thumb.jpg")) { item.thumb = "thumb.jpg" }
        }
        item.notes = notes.isEmpty ? nil : notes
        try item.save()
        return item
    }

    // MARK: Scenes

    private static func convertScene(src: URL, out: URL, item: inout LibraryItem, notes: inout [String]) throws {
        let fm = FileManager.default
        var sceneRoot = src
        var tmp: URL?
        let pkg = src.appendingPathComponent("scene.pkg")
        if fm.fileExists(atPath: pkg.path) {
            let t = fm.temporaryDirectory.appendingPathComponent("porter-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tmp = t
            try PKG.extract(pkg, to: t)
            sceneRoot = t
        }
        defer { if let tmp { try? fm.removeItem(at: tmp) } }

        let referenced = referencedTextures(sceneRoot)
        let imagesDir = out.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let rootPath = sceneRoot.resolvingSymlinksInPath().path
        var best: (rel: String, area: Int, referenced: Bool)?
        var failures = 0

        let en = fm.enumerator(at: sceneRoot, includingPropertiesForKeys: nil)
        while let f = en?.nextObject() as? URL {
            guard f.pathExtension.lowercased() == "tex" else { continue }
            var relSource = f.resolvingSymlinksInPath().path
            if relSource.hasPrefix(rootPath + "/") { relSource = String(relSource.dropFirst(rootPath.count + 1)) }
            guard let data = try? Data(contentsOf: f) else { continue }
            let result: TexDecoder.Result
            do { result = try TexDecoder.decode(data) } catch { failures += 1; continue }

            switch result {
            case .video(let d):
                if item.video == nil {
                    try d.write(to: out.appendingPathComponent("video.mp4"))
                    item.video = "video.mp4"
                }
            case .image(let cg, let isMask):
                // Skip masks, noise and tiny UI bits; keep anything that could be a wallpaper.
                guard !isMask, cg.width >= 480, cg.height >= 270 else { continue }
                let name = (relSource as NSString).deletingPathExtension
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "materials_", with: "") + ".png"
                let rel = "images/" + safeName(name)
                do { try writePNG(cg, to: out.appendingPathComponent(rel)) } catch { continue }
                item.stills.append(rel)
                let area = cg.width * cg.height
                let isRef = referenced.contains(relSource.lowercased())
                if best == nil || (isRef && !best!.referenced) || (isRef == best!.referenced && area > best!.area) {
                    best = (rel, area, isRef)
                }
            }
        }

        if let best { item.main = best.rel }
        if item.stills.count > 1 {
            notes.append("This scene was built from \(item.stills.count) layers. The biggest background was picked; use “Choose Image…” to pick another.")
        }
        if failures > 0 { notes.append("\(failures) texture(s) used a format that couldn't be converted.") }
        notes.append("Scene wallpapers are converted to still images; their animations and effects don't carry over.")
        if item.video != nil { notes.append("A video was found inside this scene and can be played live.") }
    }

    /// Textures used by image layers in scene.json — these are the likely backgrounds.
    private static func referencedTextures(_ root: URL) -> Set<String> {
        var set = Set<String>()
        guard let scene = json(root.appendingPathComponent("scene.json")),
              let objects = scene["objects"] as? [[String: Any]] else { return set }
        for obj in objects {
            guard let img = obj["image"] as? String, let imgRel = PKG.safeRelativePath(img),
                  let model = json(root.appendingPathComponent(imgRel)),
                  let mat = model["material"] as? String, let matRel = PKG.safeRelativePath(mat),
                  let material = json(root.appendingPathComponent(matRel)),
                  let passes = material["passes"] as? [[String: Any]] else { continue }
            for pass in passes {
                for t in (pass["textures"] as? [Any]) ?? [] {
                    if let name = t as? String { set.insert("materials/\(name).tex".lowercased()) }
                }
            }
        }
        return set
    }

    // MARK: Helpers

    static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        var r = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while r.hasPrefix(".") { r.removeFirst() }
        if r.isEmpty { r = "Wallpaper" }
        return String(r.prefix(80))
    }

    static func videoFrame(_ url: URL) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        if let img = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) { return img }
        return try gen.copyCGImage(at: .zero, actualTime: nil)
    }

    static func writePNG(_ cg: CGImage, to url: URL) throws {
        guard let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw PorterError.message("Couldn't encode PNG")
        }
        try d.write(to: url)
    }

    @discardableResult
    static func writeThumbnail(from url: URL, to dest: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 640,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let d = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return false }
        return (try? d.write(to: dest)) != nil
    }
}

enum Desktop {
    /// Sets a still image as the wallpaper on every display.
    static func setStill(_ url: URL) throws {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        }
    }
}
