import AVFoundation
import CoreMedia
import VideoToolbox

/// Writes camera frames straight into a small MP4: every frame is shrunk to
/// the chosen resolution and extra frames are dropped to reach the chosen
/// frame rate, so the full-size video never touches the disk.
/// All calls except `finish` happen on the capture queue.
nonisolated final class VideoWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): "Recording failed: \(message)" }
        }
    }

    let url: URL
    let resolution: Resolution
    let codec: VideoCodec
    let fps: Int
    let withAudio: Bool

    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var transfer: VTPixelTransferSession?
    private var startTime: CMTime?
    private var nextDue: CMTime = .zero
    private var lastTime: CMTime = .zero
    private var frameLength: CMTime { CMTime(value: 1, timescale: CMTimeScale(fps)) }
    private(set) var error: Error?
    private(set) var framesWritten = 0
    private(set) var outputSize: CGSize = .zero

    init(url: URL, resolution: Resolution, codec: VideoCodec, fps: Int, withAudio: Bool) {
        self.url = url
        self.resolution = resolution
        self.codec = codec
        self.fps = fps
        self.withAudio = withAudio
    }

    /// Seconds recorded so far.
    var seconds: Double {
        guard let startTime else { return 0 }
        return max(0, (lastTime - startTime).seconds)
    }

    func append(video sample: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        append(pixels: pixels, time: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func append(pixels: CVPixelBuffer, time: CMTime) {
        guard error == nil else { return }
        if writer == nil {
            do { try setUp(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), start: time) } catch {
                self.error = error
                return
            }
        }
        guard let writer, writer.status == .writing, let videoIn, let adaptor else {
            if let writer, writer.status == .failed { error = writer.error }
            return
        }
        // Drop frames to reach the chosen frame rate.
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 4))
        guard time + tolerance >= nextDue else { return }
        while nextDue <= time { nextDue = nextDue + frameLength }
        guard videoIn.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var small: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &small)
        guard let small, let transfer else { return }
        guard VTPixelTransferSessionTransferImage(transfer, from: pixels, to: small) == noErr else { return }
        if adaptor.append(small, withPresentationTime: time) {
            framesWritten += 1
            lastTime = time
        } else if writer.status == .failed {
            error = writer.error
        }
    }

    func append(audio sample: CMSampleBuffer) {
        guard error == nil, let writer, writer.status == .writing, let audioIn, let startTime else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= startTime, audioIn.isReadyForMoreMediaData else { return }
        audioIn.append(sample)
    }

    private func setUp(width: Int, height: Int, start: CMTime) throws {
        let size = resolution.outputSize(for: CGSize(width: width, height: height))
        outputSize = size
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: resolution.videoBitRate(codec: codec),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 4,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoIn) else { throw WriterError.failed("this size isn’t supported") }
        writer.add(videoIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])

        if withAudio {
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: resolution.audioBitRate,
            ])
            audioIn.expectsMediaDataInRealTime = true
            if writer.canAdd(audioIn) {
                writer.add(audioIn)
                self.audioIn = audioIn
            }
        }

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let session else { throw WriterError.failed("couldn’t start the scaler") }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)

        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "couldn’t start writing")
        }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        self.videoIn = videoIn
        self.adaptor = adaptor
        self.transfer = session
        startTime = start
        nextDue = start
        lastTime = start
    }

    /// Closes the file. Returns its URL, or throws if nothing usable was written.
    func finish() async throws -> URL {
        if let error { writer?.cancelWriting(); try? FileManager.default.removeItem(at: url); throw error }
        guard let writer, framesWritten > 0 else {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw WriterError.failed("no video was captured")
        }
        videoIn?.markAsFinished()
        audioIn?.markAsFinished()
        writer.endSession(atSourceTime: lastTime + frameLength)
        await writer.finishWriting()
        if writer.status != .completed {
            throw WriterError.failed(writer.error?.localizedDescription ?? "couldn’t finish the file")
        }
        return url
    }
}
