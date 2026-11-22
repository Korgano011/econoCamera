import AVFoundation
import Foundation
import Speech

/// Audio to text, entirely on this device (audio never leaves it).
nonisolated enum Transcriber {
    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Speech recognition permission was not granted. Turn it on in Settings › Privacy & Security › Speech Recognition."
            case .unavailable:
                "Speech recognition isn’t available on this device right now."
            case .failed(let message):
                message
            }
        }
    }

    /// Turns the sound in any audio or video file into text. `progress`
    /// gets 0…1 as the audio is worked through.
    static func transcribe(url source: URL, timestamps: Bool,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let url = try await AudioExtractor.speechFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = max(1, await Library.duration(of: url))
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return try await analyze(url: url, locale: locale, duration: duration,
                                     timestamps: timestamps, progress: progress)
        }
        guard await requestAuthorization() else { throw TranscriptionError.notAuthorized }
        return try await recognize(url: url, duration: duration, timestamps: timestamps, progress: progress)
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: SpeechAnalyzer (iOS 26+)

    private static func analyze(url: URL, locale: Locale, duration: Double, timestamps: Bool,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // The first time, the system downloads the on-device language model.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        let collect = Task {
            var pieces: [Piece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                if !text.isEmpty { pieces.append(Piece(start: start, end: end, text: text)) }
                if end.isFinite { progress(min(1, end / duration)) }
            }
            return pieces
        }
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }
        let pieces = try await collect.value
        progress(1)
        return format(pieces, timestamps: timestamps)
    }

    // MARK: SFSpeechRecognizer fallback

    private static func recognize(url: URL, duration: Double, timestamps: Bool,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let state = RecognizeState()
            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    // On device, each pause starts a new stretch; keep each finished one.
                    let segments = result.bestTranscription.segments
                    if let last = segments.last {
                        progress(min(1, (last.timestamp + last.duration) / duration))
                    }
                    if result.speechRecognitionMetadata != nil || result.isFinal {
                        let text = result.bestTranscription.formattedString
                        let start = segments.first?.timestamp ?? 0
                        let end = segments.last.map { $0.timestamp + $0.duration } ?? start
                        state.add(Piece(start: start, end: end, text: text))
                    }
                    if result.isFinal {
                        state.finish { continuation.resume(returning: format(state.pieces, timestamps: timestamps)) }
                    }
                }
                if let error {
                    state.finish {
                        if state.pieces.isEmpty {
                            continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                        } else {
                            continuation.resume(returning: format(state.pieces, timestamps: timestamps))
                        }
                    }
                }
            }
        }
    }

    private final class RecognizeState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pieces: [Piece] = []
        private var done = false

        func add(_ piece: Piece) {
            lock.lock(); defer { lock.unlock() }
            guard !piece.text.isEmpty, pieces.last?.text != piece.text else { return }
            pieces.append(piece)
        }

        func finish(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }

    // MARK: Formatting

    struct Piece {
        let start: Double
        let end: Double
        let text: String
    }

    /// Without timestamps: sentences flow together, with a new paragraph
    /// after a pause of 2 s or more. With timestamps: one line per stretch.
    static func format(_ pieces: [Piece], timestamps: Bool) -> String {
        if timestamps {
            return pieces.map { "[\(TimeText.clock($0.start))] \($0.text)" }.joined(separator: "\n")
        }
        var paragraphs: [String] = []
        var current = ""
        var lastEnd: Double?
        for piece in pieces {
            if let lastEnd, piece.start - lastEnd >= 2, !current.isEmpty {
                paragraphs.append(current)
                current = ""
            }
            current += current.isEmpty ? piece.text : " " + piece.text
            lastEnd = piece.end
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }
}
