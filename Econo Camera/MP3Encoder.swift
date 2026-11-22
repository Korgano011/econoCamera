import AVFoundation
import Foundation

/// The built-in MP3 converter: decodes any audio or video file macOS can
/// read and encodes it to MP3 with the bundled LAME encoder.
nonisolated enum MP3Encoder {
    enum EncodeError: LocalizedError {
        case noAudio
        case encoder(String)
        case read(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "That file has no audio track."
            case .encoder(let message): "MP3 encoder error: \(message)"
            case .read(let message): "Couldn’t read the file: \(message)"
            }
        }
    }

    /// Converts `source` to an MP3 at `destination`. `bitrate` is in kbps.
    /// `progress` gets 0…1. If it fails or is cancelled, no file is left behind.
    static func convert(source: URL, to destination: URL, bitrate: Int, title: String?,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await encode(source: source, to: destination, bitrate: bitrate, title: title, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func encode(source: URL, to destination: URL, bitrate: Int, title: String?,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let firstTrack = tracks.first else { throw EncodeError.noAudio }
        let duration = max(0.1, try await asset.load(.duration).seconds)

        // Keep the source's channel count (mono stays mono) and use a sample
        // rate MP3 supports.
        var sourceChannels = 2
        var sourceRate = 44_100.0
        if let description = try await firstTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sourceChannels = Int(asbd.mChannelsPerFrame)
            sourceRate = asbd.mSampleRate
        }
        let channels = sourceChannels == 1 ? 1 : 2
        let rate = [48_000.0, 44_100.0, 32_000.0].contains(sourceRate) ? sourceRate : 44_100.0

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(output) else { throw EncodeError.read("unsupported audio format") }
        reader.add(output)

        guard let lame = lame_init() else { throw EncodeError.encoder("couldn’t start") }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(rate))
        lame_set_out_samplerate(lame, Int32(rate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(lame, Int32(bitrate))
        lame_set_VBR(lame, vbr_off)
        lame_set_quality(lame, 2)          // 2 = high quality, still fast
        lame_set_bWriteVbrTag(lame, 0)     // plain CBR stream, no header to patch
        if let title, !title.isEmpty {
            id3tag_init(lame)
            id3tag_v2_only(lame)
            id3tag_set_title(lame, title)
            id3tag_set_comment(lame, "Made with Econo Camera")
        }
        guard lame_init_params(lame) >= 0 else { throw EncodeError.encoder("bad settings") }

        guard reader.startReading() else {
            throw EncodeError.read(reader.error?.localizedDescription ?? "unknown error")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var pcm: [Int16] = []
        var mp3: [UInt8] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            pcm = [Int16](repeating: 0, count: byteCount / 2)
            let status = pcm.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw EncodeError.read("bad audio data") }

            let needed = Int(1.25 * Double(frames)) + 7200
            if mp3.count < needed { mp3 = [UInt8](repeating: 0, count: needed) }
            let written: Int32 = pcm.withUnsafeMutableBufferPointer { pcmPtr in
                mp3.withUnsafeMutableBufferPointer { out in
                    if channels == 2 {
                        lame_encode_buffer_interleaved(lame, pcmPtr.baseAddress, Int32(frames),
                                                       out.baseAddress, Int32(out.count))
                    } else {
                        lame_encode_buffer(lame, pcmPtr.baseAddress, nil, Int32(frames),
                                           out.baseAddress, Int32(out.count))
                    }
                }
            }
            guard written >= 0 else { throw EncodeError.encoder("code \(written)") }
            if written > 0 { try handle.write(contentsOf: mp3[0..<Int(written)]) }

            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if time.isFinite { progress(min(0.99, time / duration)) }
        }
        if reader.status == .failed {
            throw EncodeError.read(reader.error?.localizedDescription ?? "unknown error")
        }

        if mp3.count < 7200 { mp3 = [UInt8](repeating: 0, count: 7200) }
        let flushed: Int32 = mp3.withUnsafeMutableBufferPointer { out in
            lame_encode_flush(lame, out.baseAddress, Int32(out.count))
        }
        if flushed > 0 { try handle.write(contentsOf: mp3[0..<Int(flushed)]) }
        progress(1)
    }
}
