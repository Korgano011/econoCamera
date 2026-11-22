import AVFoundation
import CoreImage
import Observation
import SwiftUI
import UIKit

/// Runs the camera. Video frames are shrunk and written as they arrive
/// (see VideoWriter), photos are shrunk before saving, and panoramas are
/// stitched live (see PanoStitcher).
@Observable final class CameraModel {
    enum Mode: String, CaseIterable, Identifiable {
        case video = "Video"
        case photo = "Photo"
        case pano = "Pano"
        var id: String { rawValue }
    }

    enum Access { case unknown, granted, denied, noCamera }

    var mode: Mode = .video { didSet { if mode != oldValue { configureForMode() } } }
    private(set) var access: Access = .unknown
    private(set) var isRecording = false
    private(set) var isPanning = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var panoStatus: PanoStitcher.Status?
    private(set) var busy = false
    private(set) var lastSaved: URL?
    private(set) var flash = false
    var message: String?

    let engine = CaptureEngine()
    private var timer: Timer?
    weak var library: Library?

    // MARK: Start / stop

    func start() async {
        #if targetEnvironment(simulator)
        access = .noCamera
        return
        #else
        guard await AVCaptureDevice.requestAccess(for: .video) else { access = .denied; return }
        let sound = UserDefaults.standard.bool(forKey: Prefs.sound)
        let micOK = sound ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard engine.hasCamera else { access = .noCamera; return }
        access = .granted
        engine.onPano = { [weak self] status in
            Task { @MainActor in self?.panoUpdate(status) }
        }
        engine.configure(mode: mode, withMic: micOK)
        engine.startRunning()
        #endif
    }

    func stop() {
        if isRecording { toggleRecording() }
        if isPanning { finishPano() }
        engine.stopRunning()
    }

    private func configureForMode() {
        guard access == .granted, !isRecording, !isPanning else { return }
        engine.configure(mode: mode, withMic: UserDefaults.standard.bool(forKey: Prefs.sound)
                         && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    func switchCamera() {
        guard !isRecording, !isPanning else { return }
        engine.switchCamera(mode: mode)
    }

    // MARK: Shutter

    func shutter() {
        switch mode {
        case .video: toggleRecording()
        case .photo: takePhoto()
        case .pano: isPanning ? finishPano() : startPano()
        }
    }

    private func toggleRecording() {
        if isRecording {
            isRecording = false
            timer?.invalidate()
            busy = true
            Task {
                do {
                    let url = try await engine.stopRecording()
                    await saved(url)
                } catch {
                    message = error.localizedDescription
                }
                busy = false
            }
        } else {
            guard let library else { return }
            let resolution = Resolution.current
            let url = library.newURL(.video, prefix: "Video", suffix: " \(resolution.label)", ext: "mp4")
            let sound = UserDefaults.standard.bool(forKey: Prefs.sound)
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            engine.startRecording(VideoWriter(url: url, resolution: resolution, codec: .current,
                                              fps: FrameRate.current.rawValue, withAudio: sound))
            isRecording = true
            elapsed = 0
            let started = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func takePhoto() {
        guard let library else { return }
        let resolution = Resolution.current
        let url = library.newURL(.photo, prefix: "Photo", suffix: " \(resolution.label)", ext: "jpg")
        busy = true
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flash = false
        }
        Task {
            do {
                try await engine.takePhoto(resolution: resolution, to: url)
                await saved(url)
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func startPano() {
        isPanning = true
        panoStatus = nil
        engine.startPano(resolution: .current)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func panoUpdate(_ status: PanoStitcher.Status) {
        guard isPanning else { return }
        panoStatus = status
        if status.frames >= PanoStitcher.maxFrames { finishPano() }
    }

    func finishPano() {
        guard isPanning, let library else { return }
        isPanning = false
        busy = true
        let resolution = Resolution.current
        let url = library.newURL(.pano, prefix: "Pano", suffix: " \(resolution.label)", ext: "jpg")
        Task {
            do {
                try await engine.finishPano(resolution: resolution, to: url)
                await saved(url)
            } catch {
                message = error.localizedDescription
            }
            panoStatus = nil
            busy = false
        }
    }

    private func saved(_ url: URL) async {
        UIApplication.shared.isIdleTimerDisabled = false
        lastSaved = url
        library?.refresh()
        if UserDefaults.standard.bool(forKey: Prefs.saveToPhotos) {
            await library?.saveToPhotos(url)
        }
    }
}

/// The AVFoundation side, run on its own queues.
nonisolated final class CaptureEngine: NSObject, @unchecked Sendable,
                                       AVCaptureVideoDataOutputSampleBufferDelegate,
                                       AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "EconoCamera.session")
    private let captureQueue = DispatchQueue(label: "EconoCamera.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewObservation: NSKeyValueObservation?

    // Touched only on captureQueue:
    private var writer: VideoWriter?
    private var stitcher: PanoStitcher?
    private var photoDelegates: [PhotoDelegate] = []

    var onPano: (@Sendable (PanoStitcher.Status) -> Void)?

    var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    // MARK: Setup

    func configure(mode: CameraModel.Mode, withMic: Bool) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            // Video and pano only ever need 720p frames; photos use the
            // photo preset (4:3) and are shrunk afterwards.
            let preset: AVCaptureSession.Preset = mode == .photo ? .photo : .hd1280x720
            if session.canSetSessionPreset(preset) { session.sessionPreset = preset }

            if videoInput == nil, let device = camera(position) , let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                makeCoordinator(device)
            }
            if withMic, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            } else if !withMic, let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
                session.addOutput(videoOutput)
            }
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
                session.addOutput(audioOutput)
            }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .speed
            }
        }
    }

    private func camera(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    func startRunning() { sessionQueue.async { [self] in if !session.isRunning { session.startRunning() } } }
    func stopRunning() { sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } } }

    func switchCamera(mode: CameraModel.Mode) {
        sessionQueue.async { [self] in
            let next: AVCaptureDevice.Position = position == .back ? .front : .back
            guard let device = camera(next), let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                position = next
            } else if let videoInput {
                session.addInput(videoInput)
            }
            session.commitConfiguration()
            makeCoordinator(device)
        }
    }

    /// Called by the preview view so capture follows how the phone is held.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        sessionQueue.async { [self] in
            if let device = videoInput?.device { makeCoordinator(device) }
        }
    }

    private func makeCoordinator(_ device: AVCaptureDevice) {
        DispatchQueue.main.async { [self] in
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
                [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    if let connection = self?.previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
            }
        }
    }

    /// Points the recorded/photographed picture upright for how the phone
    /// is held right now.
    private func setCaptureRotation(on connection: AVCaptureConnection?) {
        let angle: CGFloat = DispatchQueue.main.sync { rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90 }
        if let connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Video

    func startRecording(_ writer: VideoWriter) {
        sessionQueue.async { [self] in
            setCaptureRotation(on: videoOutput.connection(with: .video))
            captureQueue.async { self.writer = writer }
        }
    }

    func stopRecording() async throws -> URL {
        let writer: VideoWriter? = await withCheckedContinuation { done in
            captureQueue.async {
                let current = self.writer
                self.writer = nil
                done.resume(returning: current)
            }
        }
        guard let writer else { throw VideoWriter.WriterError.failed("nothing was recording") }
        return try await writer.finish()
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if output === videoOutput {
            writer?.append(video: sampleBuffer)
            if let stitcher, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
               let status = stitcher.add(CIImage(cvPixelBuffer: pixels)) {
                onPano?(status)
            }
        } else if output === audioOutput {
            writer?.append(audio: sampleBuffer)
        }
    }

    // MARK: Pano

    func startPano(resolution: Resolution) {
        sessionQueue.async { [self] in
            setCaptureRotation(on: videoOutput.connection(with: .video))
            captureQueue.async { self.stitcher = PanoStitcher(resolution: resolution) }
        }
    }

    func finishPano(resolution: Resolution, to url: URL) async throws {
        let stitcher: PanoStitcher? = await withCheckedContinuation { done in
            captureQueue.async {
                let current = self.stitcher
                self.stitcher = nil
                done.resume(returning: current)
            }
        }
        guard let stitcher else { throw PanoStitcher.PanoError.tooShort }
        try await Task.detached {
            let image = try stitcher.finish(resolution: resolution)
            try ImageFile.writeJPEG(image, to: url)
        }.value
    }

    // MARK: Photo

    func takePhoto(resolution: Resolution, to url: URL) async throws {
        let data: Data = try await withCheckedThrowingContinuation { done in
            sessionQueue.async { [self] in
                setCaptureRotation(on: photoOutput.connection(with: .video))
                let delegate = PhotoDelegate { [weak self] result in
                    self?.captureQueue.async { self?.photoDelegates.removeAll { $0.finished } }
                    done.resume(with: result)
                }
                captureQueue.sync { photoDelegates.append(delegate) }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .speed
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
        try await Task.detached {
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
                  let small = ImageFile.shrink(image, to: resolution, context: Cartoonizer.context) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try ImageFile.writeJPEG(small, to: url)
        }.value
    }
}

nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<Data, Error>) -> Void
    private(set) var finished = false

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        finished = true
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CocoaError(.fileReadCorruptFile)))
        }
    }
}

/// Shows the live camera.

struct CameraPreview: UIViewRepresentable {
    let engine: CaptureEngine

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = engine.session
        view.previewLayer.videoGravity = .resizeAspect
        engine.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
