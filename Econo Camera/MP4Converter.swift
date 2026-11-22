import AVFoundation
import Foundation

/// The built-in MP4 converter: re-encodes any video this device can read (MOV,
/// M4V, MP4, screen recordings from other apps…) into a small MP4 at
/// 60p, 120p, 240p, 480p or 720p.
nonisolated enum MP4Converter {
    enum ConvertError: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "That file has no video in it. To keep just the sound, make an MP3 instead."
            case .failed(let message): "Couldn’t convert: \(message)"
            }
        }
    }

    static func convert(source: URL, to destination: URL, quality: Resolution, codec: VideoCodec,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await encode(source: source, to: destination, quality: quality, codec: codec, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func encode(source: URL, to destination: URL, quality: Resolution, codec: VideoCodec,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = max(0.1, try await asset.load(.duration).seconds)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let sourceRate = try await videoTrack.load(.nominalFrameRate)
        let size = quality.outputSize(for: naturalSize)
        let fps = Int(min(30, max(5, sourceRate > 0 ? sourceRate.rounded() : 30)))

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        guard reader.canAdd(videoOut) else { throw ConvertError.failed("can’t read this video") }
        reader.add(videoOut)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality.videoBitRate(codec: codec),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 5,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.transform = transform
        guard writer.canAdd(videoIn) else { throw ConvertError.failed("video settings not supported") }
        writer.add(videoIn)

        var audioOut: AVAssetReaderAudioMixOutput?
        var audioIn: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: quality.audioBitRate,
            ])
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioOut = out
                audioIn = input
            }
        }

        guard reader.startReading() else { throw ConvertError.failed(reader.error?.localizedDescription ?? "can’t read") }
        guard writer.startWriting() else { throw ConvertError.failed(writer.error?.localizedDescription ?? "can’t write") }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader, writer: writer)
        try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump.copy(from: videoOut, to: videoIn, label: "video") { time in
                        progress(min(0.99, time / duration))
                    }
                }
                if let audioOut, let audioIn {
                    group.addTask {
                        await pump.copy(from: audioOut, to: audioIn, label: "audio") { _ in }
                    }
                }
            }
        } onCancel: {
            pump.cancel()
        }
        try Task.checkCancellation()
        if reader.status == .failed {
            writer.cancelWriting()
            throw ConvertError.failed(reader.error?.localizedDescription ?? "read error")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ConvertError.failed(writer.error?.localizedDescription ?? "write error")
        }
        progress(1)
    }

    /// Moves samples from a reader output to a writer input on a queue.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        private let lock = NSLock()
        private var cancelled = false

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            reader.cancelReading()
            writer.cancelWriting()
        }

        private var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func copy(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, label: String,
                  time: @escaping @Sendable (Double) -> Void) async {
            let queue = DispatchQueue(label: "MP4Converter.\(label)")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData && !finished {
                        if self.isCancelled || self.reader.status != .reading {
                            finished = true
                        } else if let buffer = output.copyNextSampleBuffer() {
                            let seconds = buffer.presentationTimeStamp.seconds
                            if !input.append(buffer) {
                                finished = true
                            } else if seconds.isFinite {
                                time(seconds)
                            }
                        } else {
                            finished = true
                        }
                        if finished {
                            input.markAsFinished()
                            done.resume()
                        }
                    }
                }
            }
        }
    }
}

/// Pulls the sound out of any audio or video file into a small temporary
/// file the speech recognizer can read.
nonisolated enum AudioExtractor {
    static func speechFile(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MP3Encoder.EncodeError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        reader.add(output)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        guard reader.startReading() else {
            throw MP3Encoder.EncodeError.read(reader.error?.localizedDescription ?? "unknown error")
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let dest = buffer.int16ChannelData?[0] else { continue }
            buffer.frameLength = frames
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(frames) * 2, destination: dest)
            try file.write(from: buffer)
        }
        if reader.status == .failed {
            throw MP3Encoder.EncodeError.read(reader.error?.localizedDescription ?? "unknown error")
        }
        return url
    }
}
