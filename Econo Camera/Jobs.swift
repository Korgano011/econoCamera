import CoreImage
import Foundation
import Observation

/// Background work: MP3s, smaller MP4s, text and cartoons. Progress is keyed
/// by the source file.
@Observable final class Jobs {
    enum Kind: Hashable { case mp3, mp4, text, cartoon }

    private(set) var progress: [URL: [Kind: Double]] = [:]
    var errors: [URL: String] = [:]

    func fraction(_ kind: Kind, for key: URL) -> Double? { progress[key]?[kind] }

    private func begin(_ kind: Kind, _ key: URL) -> Bool {
        guard progress[key]?[kind] == nil else { return false }
        progress[key, default: [:]][kind] = 0
        errors[key] = nil
        return true
    }

    private func update(_ kind: Kind, _ key: URL, _ value: Double) {
        if progress[key]?[kind] != nil { progress[key]?[kind] = value }
    }

    private func end(_ kind: Kind, _ key: URL) {
        progress[key]?[kind] = nil
        if progress[key]?.isEmpty == true { progress[key] = nil }
    }

    func mp3(source: URL, library: Library, done: (@MainActor (URL) -> Void)? = nil) {
        guard begin(.mp3, source) else { return }
        let destination = library.newURL(.converted, from: source, ext: "mp3")
        let bitrate = UserDefaults.standard.integer(forKey: Prefs.mp3Bitrate)
        let title = source.deletingPathExtension().lastPathComponent
        Task {
            do {
                try await Task.detached {
                    try await MP3Encoder.convert(source: source, to: destination, bitrate: bitrate, title: title) { value in
                        Task { @MainActor in self.update(.mp3, source, value) }
                    }
                }.value
                done?(destination)
            } catch {
                errors[source] = error.localizedDescription
            }
            end(.mp3, source)
            library.refresh()
        }
    }

    func mp4(source: URL, resolution: Resolution, library: Library, done: (@MainActor (URL) -> Void)? = nil) {
        guard begin(.mp4, source) else { return }
        var base = source.deletingPathExtension().lastPathComponent
        for r in Resolution.allCases where base.hasSuffix(" \(r.label)") { base = String(base.dropLast(r.label.count + 1)) }
        let destination = Library.unique(in: Library.folder(.converted), base: "\(base) \(resolution.label)", ext: "mp4")
        let codec = VideoCodec.current
        Task {
            do {
                try await Task.detached {
                    try await MP4Converter.convert(source: source, to: destination, quality: resolution, codec: codec) { value in
                        Task { @MainActor in self.update(.mp4, source, value) }
                    }
                }.value
                done?(destination)
            } catch {
                errors[source] = error.localizedDescription
            }
            end(.mp4, source)
            library.refresh()
        }
    }

    /// Turns speech into text and saves it in the Text folder.
    func text(source: URL, library: Library, done: (@MainActor (String, URL) -> Void)? = nil) {
        guard begin(.text, source) else { return }
        let timestamps = UserDefaults.standard.bool(forKey: Prefs.timestamps)
        Task {
            do {
                let text = try await Task.detached {
                    try await Transcriber.transcribe(url: source, timestamps: timestamps) { value in
                        Task { @MainActor in self.update(.text, source, value) }
                    }
                }.value
                let saved = text.isEmpty ? "(No speech was heard.)" : text
                let url = library.newURL(.text, from: source, ext: "txt")
                try saved.write(to: url, atomically: true, encoding: .utf8)
                done?(saved, url)
            } catch {
                errors[source] = error.localizedDescription
            }
            end(.text, source)
            library.refresh()
        }
    }

    func cartoon(source: URL, image: CIImage, movie: Cartoonizer.Movie, library: Library,
                 done: (@MainActor (URL) -> Void)? = nil) {
        guard begin(.cartoon, source) else { return }
        var base = source.deletingPathExtension().lastPathComponent
        for r in Resolution.allCases where base.hasSuffix(" \(r.label)") { base = String(base.dropLast(r.label.count + 1)) }
        let name = "\(base) \(movie.style.name) \(movie.animation.name) \(movie.resolution.label)"
        let isStill = movie.animation == .still
        let destination = Library.unique(in: Library.folder(.cartoon), base: name, ext: isStill ? "jpg" : "mp4")
        Task {
            do {
                try await Task.detached {
                    if isStill {
                        guard let cg = Cartoonizer.still(image, style: movie.style, resolution: movie.resolution) else {
                            throw Cartoonizer.CartoonError.failed("couldn’t draw it")
                        }
                        try ImageFile.writeJPEG(cg, to: destination)
                    } else {
                        try await Cartoonizer.animate(image, movie: movie, to: destination) { value in
                            Task { @MainActor in self.update(.cartoon, source, value) }
                        }
                    }
                }.value
                done?(destination)
            } catch {
                errors[source] = error.localizedDescription
            }
            end(.cartoon, source)
            library.refresh()
        }
    }
}
