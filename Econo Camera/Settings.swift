import AVFoundation
import Foundation

/// The five sizes Econo Camera records and saves in. Everything is tuned
/// to use as little space on the phone as possible, not to look its best.
nonisolated enum Resolution: Int, CaseIterable, Identifiable, Codable, Sendable {
    case p60 = 60
    case p120 = 120
    case p240 = 240
    case p480 = 480
    case p720 = 720

    var id: Int { rawValue }
    var lines: Int { rawValue }
    var label: String { "\(rawValue)p" }

    var note: String {
        switch self {
        case .p60: "Postage stamp. Tiniest files — shapes and colors only."
        case .p120: "Very tiny. Faces and big shapes."
        case .p240: "Small. Good for most memories and notes."
        case .p480: "Clear enough for most things, still small."
        case .p720: "Sharp. Still far smaller than a normal phone video."
        }
    }

    /// Video bit rate in bits per second, for HEVC. H.264 uses 40% more.
    func videoBitRate(codec: VideoCodec) -> Int {
        let hevc: Int = switch self {
        case .p60: 35_000
        case .p120: 90_000
        case .p240: 220_000
        case .p480: 550_000
        case .p720: 1_100_000
        }
        return codec == .hevc ? hevc : hevc * 14 / 10
    }

    /// Mono AAC audio bit rate.
    var audioBitRate: Int {
        switch self {
        case .p60, .p120, .p240: 48_000
        case .p480: 64_000
        case .p720: 96_000
        }
    }

    /// Rough disk use in megabytes per minute of video.
    func megabytesPerMinute(codec: VideoCodec, withAudio: Bool = true) -> Double {
        let bits = Double(videoBitRate(codec: codec) + (withAudio ? audioBitRate : 0))
        return bits * 60 / 8 / 1_000_000
    }

    /// Output size for a source of `size`: the shorter side becomes `lines`
    /// (never larger than the source), both sides even.
    func outputSize(for size: CGSize) -> CGSize {
        let w = max(2, abs(size.width)), h = max(2, abs(size.height))
        let short = min(w, h)
        let scale = min(1, Double(lines) / short)
        func even(_ v: Double) -> CGFloat { CGFloat(max(2, Int((v * scale / 2).rounded()) * 2)) }
        return CGSize(width: even(w), height: even(h))
    }

    static var current: Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: Prefs.resolution)) ?? .p240
    }
}

nonisolated enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc
    case h264

    var id: String { rawValue }
    var label: String { self == .hevc ? "Smallest (HEVC)" : "Plays anywhere (H.264)" }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }

    static var current: VideoCodec {
        VideoCodec(rawValue: UserDefaults.standard.string(forKey: Prefs.codec) ?? "") ?? .hevc
    }
}

nonisolated enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps10 = 10
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }

    static var current: FrameRate {
        FrameRate(rawValue: UserDefaults.standard.integer(forKey: Prefs.frameRate)) ?? .fps24
    }
}

nonisolated enum Prefs {
    static let resolution = "resolution"
    static let codec = "codec"
    static let frameRate = "frameRate"
    static let sound = "sound"
    static let saveToPhotos = "saveToPhotos"
    static let mp3Bitrate = "mp3Bitrate"
    static let timestamps = "timestamps"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            resolution: Resolution.p240.rawValue,
            codec: VideoCodec.hevc.rawValue,
            frameRate: FrameRate.fps24.rawValue,
            sound: true,
            saveToPhotos: false,
            mp3Bitrate: 64,
            timestamps: false,
        ])
    }
}

nonisolated enum TimeText {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func fileStamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter.string(from: date)
    }
}

nonisolated enum SizeText {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func megabytes(_ value: Double) -> String {
        value < 1 ? String(format: "%.2f MB", value) : String(format: "%.1f MB", value)
    }
}
