import AVFoundation
import SwiftUI

struct CameraView: View {
    @Environment(CameraModel.self) private var camera
    @Environment(Library.self) private var library
    @Environment(Navigation.self) private var navigation
    @AppStorage(Prefs.resolution) private var resolutionRaw = Resolution.p240.rawValue
    @AppStorage(Prefs.codec) private var codecRaw = VideoCodec.hevc.rawValue
    @AppStorage(Prefs.sound) private var sound = true
    @State private var showSettings = false
    @State private var showHelp = false

    private var resolution: Resolution { Resolution(rawValue: resolutionRaw) ?? .p240 }
    private var codec: VideoCodec { VideoCodec(rawValue: codecRaw) ?? .hevc }
    private var locked: Bool { camera.isRecording || camera.isPanning }

    var body: some View {
        @Bindable var camera = camera
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.access {
            case .granted:
                CameraPreview(engine: camera.engine).ignoresSafeArea(edges: .horizontal)
            case .denied:
                notice("Camera access is off", "Turn it on in Settings › Econo Camera › Camera.", button: true)
            case .noCamera:
                notice("No camera here", "This device (or the Simulator) has no camera. The Cartoon, Convert and Text tabs still work.")
            case .unknown:
                ProgressView().tint(.white)
            }
            if camera.flash { Color.white.ignoresSafeArea().transition(.opacity) }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if camera.isPanning { panoGuide }
                bottomBar
            }
        }
        .task { await camera.start() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHelp) { HowItWorksView() }
        .alert("Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("OK") { camera.message = nil }
        } message: {
            Text(camera.message ?? "")
        }
    }

    private func notice(_ title: String, _ detail: String, button: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis").font(.system(size: 44))
            Text(title).font(.title3.bold())
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
            if button, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: Top: size picker and what it costs

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Resolution.allCases) { r in
                    Button {
                        resolutionRaw = r.rawValue
                    } label: {
                        Text(r.label)
                            .font(.footnote.bold().monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(r == resolution ? Color.yellow : Color.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(r == resolution ? .black : .white)
                    }
                    .disabled(locked)
                }
                Spacer(minLength: 4)
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark").font(.title3.bold())
                        .frame(width: 22, height: 22)
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }
                .foregroundStyle(.white)
                .disabled(locked)
                .accessibilityLabel("How It Works")
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3)
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }
                .foregroundStyle(.white)
                .disabled(locked)
            }
            Group {
                if camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(TimeText.clock(camera.elapsed)).monospacedDigit()
                        Text("≈ " + SizeText.megabytes(resolution.megabytesPerMinute(codec: codec, withAudio: sound) * camera.elapsed / 60))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    switch camera.mode {
                    case .video:
                        Text("\(resolution.label) video ≈ \(SizeText.megabytes(resolution.megabytesPerMinute(codec: codec, withAudio: sound))) a minute")
                    case .photo:
                        Text("\(resolution.label) photo ≈ \(photoEstimate) each")
                    case .pano:
                        Text("\(resolution.label) panorama — \(resolution.lines) pixels tall")
                    }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var photoEstimate: String {
        // JPEG at ~0.72 quality is about 1.2 bits per pixel.
        let pixels = Double(resolution.lines * resolution.lines) * 4 / 3
        return SizeText.bytes(Int64(pixels * 1.2 / 8))
    }

    // MARK: Pano guide

    private var panoGuide: some View {
        VStack(spacing: 8) {
            if let status = camera.panoStatus {
                Text(status.tooFast ? "Slow down!" : status.drift > 0.12 ? "Keep the phone level" : "Turn slowly to the side →")
                    .font(.headline)
                    .foregroundStyle(status.tooFast || status.drift > 0.12 ? .yellow : .white)
                ProgressView(value: status.progress)
                    .tint(.yellow)
                    .frame(maxWidth: 260)
                Text("\(status.frames) views — tap the button to finish").font(.caption)
            } else {
                Text("Hold still, then turn slowly…").font(.headline)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 12)
    }

    // MARK: Bottom: modes, shutter, last shot, flip

    private var bottomBar: some View {
        @Bindable var camera = camera
        return VStack(spacing: 14) {
            Picker("Mode", selection: $camera.mode) {
                ForEach(CameraModel.Mode.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .environment(\.colorScheme, .dark)
            .disabled(locked)

            HStack {
                lastShotButton.frame(width: 64)
                Spacer()
                shutterButton
                Spacer()
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .disabled(locked)
                .frame(width: 64)
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 16)
        .padding(.top, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    private var shutterButton: some View {
        Button { camera.shutter() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                switch camera.mode {
                case .video:
                    RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 31)
                        .fill(.red)
                        .frame(width: camera.isRecording ? 30 : 62, height: camera.isRecording ? 30 : 62)
                case .photo:
                    Circle().fill(.white).frame(width: 62, height: 62)
                case .pano:
                    if camera.isPanning {
                        RoundedRectangle(cornerRadius: 6).fill(.yellow).frame(width: 30, height: 30)
                    } else {
                        Circle().fill(.yellow).frame(width: 62, height: 62)
                            .overlay(Image(systemName: "pano").foregroundStyle(.black))
                    }
                }
                if camera.busy { ProgressView().tint(.black) }
            }
            .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
        }
        .disabled(camera.access != .granted || (camera.busy && !locked))
        .accessibilityLabel(camera.isRecording || camera.isPanning ? "Stop" : "Take")
    }

    @ViewBuilder private var lastShotButton: some View {
        if let url = camera.lastSaved, FileManager.default.fileExists(atPath: url.path) {
            Button { navigation.tab = .library } label: {
                Thumbnail(url: url)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
            }
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.codec) private var codecRaw = VideoCodec.hevc.rawValue
    @AppStorage(Prefs.frameRate) private var fps = FrameRate.fps24.rawValue
    @AppStorage(Prefs.sound) private var sound = true
    @AppStorage(Prefs.saveToPhotos) private var saveToPhotos = false
    @AppStorage(Prefs.mp3Bitrate) private var mp3Bitrate = 64
    @AppStorage(Prefs.timestamps) private var timestamps = false
    @AppStorage(Prefs.resolution) private var resolutionRaw = Resolution.p240.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Resolution.allCases) { r in
                        Button { resolutionRaw = r.rawValue } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.label).font(.headline)
                                    Text(r.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(SizeText.megabytes(r.megabytesPerMinute(codec: VideoCodec(rawValue: codecRaw) ?? .hevc,
                                                                             withAudio: sound)) + "/min")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if r.rawValue == resolutionRaw { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Size")
                } footer: {
                    Text("Used for videos, photos and panoramas. A normal iPhone video is about 60–400 MB a minute.")
                }
                Section("Video") {
                    Picker("Frames per second", selection: $fps) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Video type", selection: $codecRaw) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Record sound", isOn: $sound)
                }
                Section {
                    Toggle("Also save to Photos", isOn: $saveToPhotos)
                } footer: {
                    Text("Everything is always kept in \(Library.filesHint). Turn this on to also put a copy in the Photos app.")
                }
                Section("MP3 & Text") {
                    Picker("MP3 quality", selection: $mp3Bitrate) {
                        ForEach([32, 48, 64, 96, 128, 192], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                    Toggle("Times in text like [1:05]", isOn: $timestamps)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
