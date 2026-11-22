import Foundation
import Observation

/// Something kept in the repository: a folder holding the file, any MP3 or
/// text made from it, and an optional note.
struct RepositoryItem: Identifiable, Hashable {
    let folder: URL
    let savedOn: Date
    let size: Int64
    let note: String
    /// Text made from the sound, if any (used for searching).
    let transcript: String
    let files: [URL]

    var id: URL { folder }
    var title: String { folder.lastPathComponent }

    /// The file this item is about: the video or picture if there is one.
    var main: URL? {
        files.first { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            ?? files.first { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            ?? files.first { $0.pathExtension.lowercased() == "mp3" }
            ?? files.first
    }
}

/// A folder the person picked, remembered between launches.
@Observable final class ChosenFolder {
    private(set) var url: URL
    private(set) var isCustom = false
    private let bookmarkKey: String
    private let defaultURL: URL
    private var scopedURL: URL?

    init(bookmarkKey: String, defaultURL: URL) {
        self.bookmarkKey = bookmarkKey
        self.defaultURL = defaultURL
        url = defaultURL
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let saved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               saved.startAccessingSecurityScopedResource() {
                scopedURL = saved
                url = saved
                isCustom = true
                if stale, let fresh = try? saved.bookmarkData() {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
            }
        }
        ensure()
    }

    /// Starts using a folder picked in the folder picker.
    func use(_ picked: URL) throws {
        let access = picked.startAccessingSecurityScopedResource()
        do {
            let data = try picked.bookmarkData()
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            if access { picked.stopAccessingSecurityScopedResource() }
            throw error
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = access ? picked : nil
        url = picked
        isCustom = true
    }

    func useDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        url = defaultURL
        isCustom = false
        ensure()
    }

    func ensure() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// The repository: a long-term folder (inside Econo Camera by default, or
/// iCloud Drive, a USB drive…) where finished work is kept for future use,
/// with a note and searchable text.
@Observable final class Repository {
    static let noteFileName = "Note.txt"
    /// Remembers which Library folder each file came from, for copying back.
    static let kindsFileName = ".kinds.json"

    let folder: ChosenFolder
    private(set) var items: [RepositoryItem] = []
    var lastError: String?

    var folderURL: URL { folder.url }

    init() {
        folder = ChosenFolder(bookmarkKey: "repositoryFolderBookmark",
                              defaultURL: Library.root.appendingPathComponent("Repository", isDirectory: true))
        refresh()
    }

    /// Where the repository is, in words like the Files app uses.
    var displayPath: String {
        guard folder.isCustom else { return "On My iPhone › Econo Camera › Repository" }
        let parts = folderURL.standardizedFileURL.pathComponents
        if let i = parts.firstIndex(of: "Mobile Documents"), i + 1 < parts.count {
            let rest = parts[(i + 2)...]
            let base = parts[i + 1] == "com~apple~CloudDocs" ? "iCloud Drive" : parts[i + 1]
            return ([base] + rest).joined(separator: " › ")
        }
        if let i = parts.firstIndex(of: "Documents"), parts.contains("Application") || parts.contains("Containers") {
            return (["On My iPhone"] + parts[(i + 1)...]).joined(separator: " › ")
        }
        return parts.suffix(3).joined(separator: " › ")
    }

    func useFolder(_ url: URL) {
        do {
            try folder.use(url)
            refresh()
        } catch {
            lastError = "Couldn’t use that folder: \(error.localizedDescription)"
        }
    }

    func useDefaultFolder() {
        folder.useDefault()
        refresh()
    }

    func refresh() {
        folder.ensure()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        items = children.compactMap { folder -> RepositoryItem? in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true else { return nil }
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.lastPathComponent != Self.noteFileName }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let note = (try? String(contentsOf: folder.appendingPathComponent(Self.noteFileName), encoding: .utf8)) ?? ""
            let transcript = files.filter { $0.pathExtension.lowercased() == "txt" }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
            let size = files.reduce(Int64(0)) { $0 + Library.size(of: $1) }
            return RepositoryItem(folder: folder, savedOn: values?.creationDate ?? .distantPast, size: size,
                                  note: note, transcript: transcript, files: files)
        }
        .sorted { $0.savedOn > $1.savedOn }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// True if something with this name is already in the repository.
    func contains(_ item: MediaItem) -> Bool {
        items.contains { $0.title == item.title }
    }

    /// The MP3 and text made from `item` (same name, other Library folders).
    func companions(of item: MediaItem, in library: Library) -> [MediaItem] {
        library.items.filter { $0.url != item.url && $0.title == item.title && ($0.isAudio || $0.isText) }
    }

    /// Copies an item (and its MP3/text if chosen) into its own repository folder.
    @discardableResult
    func save(_ item: MediaItem, including extras: [MediaItem], note: String) -> Bool {
        folder.ensure()
        var targetFolder = folderURL.appendingPathComponent(item.title, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: targetFolder.path) {
            targetFolder = folderURL.appendingPathComponent("\(item.title) \(n)", isDirectory: true)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            var kinds: [String: String] = [:]
            for file in [item] + extras {
                let destination = targetFolder.appendingPathComponent(file.url.lastPathComponent)
                try FileManager.default.copyItem(at: file.url, to: destination)
                kinds[file.url.lastPathComponent] = file.kind.rawValue
            }
            if let data = try? JSONEncoder().encode(kinds) {
                try? data.write(to: targetFolder.appendingPathComponent(Self.kindsFileName))
            }
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try trimmed.write(to: targetFolder.appendingPathComponent(Self.noteFileName), atomically: true, encoding: .utf8)
            }
            refresh()
            return true
        } catch {
            try? FileManager.default.removeItem(at: targetFolder)
            lastError = "Couldn’t save to the repository: \(error.localizedDescription)"
            refresh()
            return false
        }
    }

    /// Copies an item's files back into the Library folders they came from.
    func restore(_ item: RepositoryItem, to library: Library) {
        var kinds: [String: String] = [:]
        if let data = try? Data(contentsOf: item.folder.appendingPathComponent(Self.kindsFileName)),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            kinds = saved
        }
        do {
            for file in item.files {
                let kind = kinds[file.lastPathComponent].flatMap(MediaKind.init(rawValue:)) ?? Self.guessKind(file)
                let destination = Library.unique(in: Library.folder(kind),
                                                 base: file.deletingPathExtension().lastPathComponent,
                                                 ext: file.pathExtension)
                try FileManager.default.copyItem(at: file, to: destination)
            }
        } catch {
            lastError = "Couldn’t copy back to the Library: \(error.localizedDescription)"
        }
        library.refresh()
    }

    private static func guessKind(_ url: URL) -> MediaKind {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "txt": return .text
        case "mp3", "m4a": return .converted
        case "jpg", "jpeg", "png", "heic":
            return name.hasPrefix("Pano") ? .pano : name.hasPrefix("Photo") ? .photo : .cartoon
        default:
            return name.hasPrefix("Video") ? .video : .cartoon
        }
    }

    func setNote(_ note: String, for item: RepositoryItem) {
        let url = item.folder.appendingPathComponent(Self.noteFileName)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        }
        refresh()
    }

    func remove(_ item: RepositoryItem) {
        do {
            try FileManager.default.removeItem(at: item.folder)
        } catch {
            lastError = "Couldn’t remove “\(item.title)”: \(error.localizedDescription)"
        }
        refresh()
    }
}
