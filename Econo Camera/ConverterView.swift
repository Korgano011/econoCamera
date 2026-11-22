import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Picking an audio or video file from Files, Photos, or Econo Camera.
struct SourcePicker: View {
    @Binding var source: URL?
    var onPick: (URL) -> Void = { _ in }
    @Environment(Library.self) private var library
    @State private var fromFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source {
                HStack {
                    Thumbnail(url: source).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(source.lastPathComponent).lineLimit(2).font(.subheadline)
                        Text(SizeText.bytes(Library.size(of: source))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Menu {
                    let media = library.items.filter { $0.isVideo || $0.isAudio }
                    if media.isEmpty { Text("No videos yet") }
                    ForEach(media.prefix(40)) { item in
                        Button(item.title) { choose(item.url) }
                    }
                } label: { Label("Econo Camera", systemImage: "camera") }
                PhotosPicker(selection: $photoItem, matching: .videos) { Label("Photos", systemImage: "photo") }
                Button { fromFiles = true } label: { Label("Files", systemImage: "folder") }
                if loading { ProgressView() }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .fileImporter(isPresented: $fromFiles, allowedContentTypes: [.audiovisualContent]) { result in
            if case .success(let url) = result, let copy = PickedFile.localCopy(of: url) { choose(copy) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loading = true
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) { choose(movie.url) }
                loading = false
                photoItem = nil
            }
        }
    }

    private func choose(_ url: URL) {
        source = url
        onPick(url)
    }
}

/// The built-in MP3 and MP4 converter.
struct ConverterView: View {
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @AppStorage(Prefs.mp3Bitrate) private var mp3Bitrate = 64
    @AppStorage(Prefs.codec) private var codec = VideoCodec.hevc.rawValue

    @State private var source: URL?
    @State private var resolution = Resolution.p240
    @State private var lastOutput: URL?

    var body: some View {
        Form {
            Section {
                SourcePicker(source: $source) { _ in lastOutput = nil }
            } header: {
                Text("1. Choose a video or audio file")
            } footer: {
                Text("Pick a big video from the Photos app to make a small copy that saves space.")
            }

            Section("2. Smaller MP4 video") {
                ResolutionPicker(selection: $resolution)
                Picker("Video type", selection: $codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Button("Convert to \(resolution.label) MP4") {
                    guard let source else { return }
                    jobs.mp4(source: source, resolution: resolution, library: library) { lastOutput = $0 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || busy(.mp4))
                if let source, let value = jobs.fraction(.mp4, for: source) {
                    ProgressView(value: value) { Text("Making MP4…").font(.caption) }
                }
            }

            Section("3. MP3 (sound only)") {
                Picker("MP3 quality", selection: $mp3Bitrate) {
                    ForEach([32, 48, 64, 96, 128, 192], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Button("Convert to MP3") {
                    guard let source else { return }
                    jobs.mp3(source: source, library: library) { lastOutput = $0 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || busy(.mp3))
                if let source, let value = jobs.fraction(.mp3, for: source) {
                    ProgressView(value: value) { Text("Making MP3…").font(.caption) }
                }
            }

            if let source, let error = jobs.errors[source] {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let lastOutput {
                Section("Done") {
                    FileRow(url: lastOutput, repositoryButton: true)
                    if let source {
                        let before = Library.size(of: source), after = Library.size(of: lastOutput)
                        if before > 0, after > 0, after < before {
                            Text("Saved \(SizeText.bytes(before - after)) (\(Int(100 - Double(after) / Double(before) * 100))% smaller).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Converted files") {
                let converted = library.items(.converted)
                if converted.isEmpty {
                    Text("Nothing converted yet. Files are saved in Library › Converted.").foregroundStyle(.secondary)
                }
                ForEach(converted.prefix(30)) { item in
                    FileRow(url: item.url)
                }
                .onDelete { offsets in
                    for index in offsets { library.delete(converted[index]) }
                }
            }
        }
        .navigationTitle("MP3 & MP4 Converter")
    }

    private func busy(_ kind: Jobs.Kind) -> Bool {
        source.map { jobs.fraction(kind, for: $0) != nil } ?? false
    }
}

/// Turns the speech in any audio or video file into text.
struct AudioToTextView: View {
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @AppStorage(Prefs.timestamps) private var timestamps = false

    @State private var source: URL?
    @State private var text = ""
    @State private var savedURL: URL?

    var body: some View {
        Form {
            Section("Choose a video or audio file") {
                SourcePicker(source: $source) { _ in run() }
                Toggle("Times like [1:05]", isOn: $timestamps)
                Button("Turn Speech into Text") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || source.map { jobs.fraction(.text, for: $0) != nil } == true)
                if let source, let value = jobs.fraction(.text, for: source) {
                    ProgressView(value: value) { Text("Listening… (on this device)").font(.caption) }
                }
                if let source, let error = jobs.errors[source] { Text(error).foregroundStyle(.red) }
            }

            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .overlay {
                        if text.isEmpty {
                            Text("The words will appear here.").foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button("Copy") { UIPasteboard.general.string = text }
                    Spacer()
                    Button("Save Changes") { save() }.disabled(savedURL == nil)
                    if let savedURL {
                        ShareLink(item: savedURL) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(text.isEmpty)
            } header: {
                Text("Text")
            } footer: {
                if let savedURL { Text("Saved as Library › Text › \(savedURL.lastPathComponent)") }
            }

            let notes = library.items(.text)
            if !notes.isEmpty {
                Section("Saved text") {
                    ForEach(notes.prefix(30)) { item in
                        Button(item.title) {
                            text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
                            savedURL = item.url
                        }
                    }
                }
            }
        }
        .navigationTitle("Audio to Text")
    }

    private func run() {
        guard let source else { return }
        jobs.text(source: source, library: library) { result, url in
            text = result
            savedURL = url
        }
    }

    private func save() {
        guard let savedURL else { return }
        do {
            try text.write(to: savedURL, atomically: true, encoding: .utf8)
            library.refresh()
        } catch {
            library.lastError = "Couldn’t save the text: \(error.localizedDescription)"
        }
    }
}
