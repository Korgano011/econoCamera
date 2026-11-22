import AVFoundation
import Foundation
import Observation
import Photos

/// Everything Econo Camera saves lives in its Documents folder, which shows
/// up in the Files app under On My iPhone › Econo Camera.
nonisolated enum MediaKind: String, CaseIterable, Identifiable, Sendable {
    case video = "Videos"
    case photo = "Photos"
    case pano = "Panoramas"
    case cartoon = "Cartoons"
    case converted = "Converted"
    case text = "Text"

    var id: String { rawValue }
    var folderName: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "video"
        case .photo: "photo"
        case .pano: "pano"
        case .cartoon: "theatermasks"
        case .converted: "arrow.triangle.2.circlepath"
        case .text: "text.quote"
        }
    }
}

nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: MediaKind
    let date: Date
    let size: Int64

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var isVideo: Bool { ["mp4", "mov", "m4v"].contains(ext) }
    var isAudio: Bool { ["mp3", "m4a", "wav", "caf", "aac"].contains(ext) }
    var isImage: Bool { ["jpg", "jpeg", "png", "heic"].contains(ext) }
    var isText: Bool { ext == "txt" }

    var symbol: String {
        if isVideo { return kind == .cartoon ? "theatermasks" : "video" }
        if isAudio { return "music.note" }
        if isText { return "text.quote" }
        return kind == .pano ? "pano" : "photo"
    }
}

@Observable final class Library {
    private(set) var items: [MediaItem] = []
    var lastError: String?

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func folder(_ kind: MediaKind) -> URL {
        let url = root.appendingPathComponent(kind.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        for kind in MediaKind.allCases { _ = Self.folder(kind) }
        refresh()
    }

    func items(_ kind: MediaKind?) -> [MediaItem] {
        guard let kind else { return items }
        return items.filter { $0.kind == kind }
    }

    func item(for url: URL) -> MediaItem? { items.first { $0.url == url } }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func refresh() {
        var found: [MediaItem] = []
        let fm = FileManager.default
        for kind in MediaKind.allCases {
            let urls = (try? fm.contentsOfDirectory(at: Self.folder(kind),
                                                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                found.append(MediaItem(url: url, kind: kind,
                                       date: values?.contentModificationDate ?? .distantPast,
                                       size: Int64(values?.fileSize ?? 0)))
            }
        }
        items = found.sorted { $0.date > $1.date }
    }

    /// A new, unused file name like "Video 2026-11-19 at 9.41.02 AM 240p.mp4".
    func newURL(_ kind: MediaKind, prefix: String, suffix: String = "", ext: String) -> URL {
        Self.unique(in: Self.folder(kind), base: "\(prefix) \(TimeText.fileStamp())\(suffix)", ext: ext)
    }

    /// A new file next to the converted/text folders named after `source`.
    func newURL(_ kind: MediaKind, from source: URL, suffix: String = "", ext: String) -> URL {
        Self.unique(in: Self.folder(kind), base: source.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    static func unique(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    func delete(_ item: MediaItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {
            lastError = "Couldn’t delete \(item.url.lastPathComponent): \(error.localizedDescription)"
        }
        refresh()
    }

    func rename(_ item: MediaItem, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != item.title else { return }
        let target = Self.unique(in: item.url.deletingLastPathComponent(), base: clean, ext: item.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
        } catch {
            lastError = "Couldn’t rename: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Copies a file into the Photos app (videos and pictures only).
    func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastError = "Econo Camera isn’t allowed to add to Photos. Turn it on in Settings › Econo Camera › Photos."
            return
        }
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
        } catch {
            lastError = "Couldn’t save to Photos: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    nonisolated static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    nonisolated static func duration(of url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    nonisolated static func videoSize(of url: URL) async -> CGSize? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    static var filesHint: String { "the Files app › On My iPhone › Econo Camera" }
}
