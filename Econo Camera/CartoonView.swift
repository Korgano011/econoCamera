import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI

/// Turns a photo or panorama into a cartoon animation of the person's choosing.
struct CartoonView: View {
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @AppStorage(Prefs.resolution) private var defaultResolution = Resolution.p240.rawValue

    @State private var source: URL?
    @State private var image: CIImage?
    @State private var previews: [CartoonStyle: UIImage] = [:]
    @State private var style = CartoonStyle.toon
    @State private var animation = CartoonAnimation.lineBoil
    @State private var resolution = Resolution.p240
    @State private var seconds = 4.0
    @State private var result: URL?
    @State private var player: AVPlayer?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingFromLibrary = false
    @State private var loadError: String?

    private var isPano: Bool {
        guard let e = image?.extent else { return false }
        return e.width > e.height * 2.2
    }

    var body: some View {
        Form {
            Section {
                if let image, let big = previews[style] ?? previews[.toon] {
                    Image(uiImage: big).resizable().scaledToFit()
                        .frame(maxHeight: isPano ? 140 : 260)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(Int(image.extent.width))×\(Int(image.extent.height))\(isPano ? " pano" : "")")
                                .font(.caption2).padding(4).background(.thinMaterial, in: Capsule()).padding(6)
                        }
                } else {
                    ContentUnavailableView("Pick a picture", systemImage: "theatermasks",
                                           description: Text("Use a photo or panorama from Econo Camera, or one from the Photos app."))
                }
                HStack {
                    Button("From Econo Camera…") { choosingFromLibrary = true }
                    Spacer()
                    PhotosPicker("From Photos…", selection: $photoItem, matching: .images)
                }
                .buttonStyle(.bordered)
                if let loadError { Text(loadError).foregroundStyle(.red) }
            } header: {
                Text("1. Picture")
            }

            if image != nil {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(CartoonStyle.allCases) { s in
                                Button { style = s } label: {
                                    VStack(spacing: 4) {
                                        Group {
                                            if let p = previews[s] {
                                                Image(uiImage: p).resizable().scaledToFill()
                                            } else {
                                                ProgressView()
                                            }
                                        }
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10)
                                            .stroke(style == s ? Color.accentColor : .clear, lineWidth: 3))
                                        Text(s.name).font(.caption2).lineLimit(1)
                                    }
                                    .frame(width: 88)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("2. Look")
                } footer: {
                    Text("Pick Original Picture to keep your picture just as it is, or Black & White for a black-and-white picture, and only add the animation.")
                }

                Section("3. Animation") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                        ForEach(CartoonAnimation.allCases) { a in
                            Button { animation = a } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: a.symbol).font(.title2)
                                    Text(a.name).font(.caption)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .background(animation == a ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(animation == a ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    if animation != .still {
                        Stepper("Length: \(Int(seconds)) seconds", value: $seconds, in: 2...12, step: 1)
                    }
                    if isPano && animation != .pan && animation != .still {
                        Text("Panoramas are shown through a moving window, so every animation also pans across.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ResolutionPicker(selection: $resolution)
                    Button {
                        make()
                    } label: {
                        Label(makeTitle,
                              systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    if let source, let value = jobs.fraction(.cartoon, for: source) {
                        ProgressView(value: value) { Text("Drawing frames…").font(.caption) }
                    }
                    if let source, let error = jobs.errors[source] { Text(error).foregroundStyle(.red) }
                } header: {
                    Text("4. Size and make")
                } footer: {
                    Text("Saved in Library › Cartoons as \(animation == .still ? "a JPEG picture" : "an MP4 video").")
                }

                if let result {
                    Section(style.keepsPhoto ? "Your animation" : "Your cartoon") {
                        if result.pathExtension == "mp4" {
                            PlayerView(player: player).frame(height: 300)
                                .listRowInsets(EdgeInsets())
                        } else {
                            AsyncPicture(url: result).frame(maxHeight: 300)
                        }
                        FileRow(url: result, repositoryButton: true)
                        Button { Task { await library.saveToPhotos(result) } } label: {
                            Label("Save a Copy to Photos", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Cartoon")
        .onAppear {
            if let url = navigation.cartoonSource {
                navigation.cartoonSource = nil
                load(url)
            }
            if source == nil { resolution = Resolution(rawValue: defaultResolution) ?? .p240 }
        }
        .onChange(of: navigation.cartoonSource) { _, url in
            if let url { navigation.cartoonSource = nil; load(url) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let file = try? await item.loadTransferable(type: PickedImage.self) {
                    load(file.url)
                } else {
                    loadError = "Couldn’t open that photo."
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $choosingFromLibrary) {
            PicturePicker { url in
                choosingFromLibrary = false
                load(url)
            }
        }
    }

    private var makeTitle: String {
        switch (style.keepsPhoto, animation == .still) {
        case (true, true): "Make Picture"
        case (true, false): "Make Animation"
        case (false, true): "Make Cartoon Picture"
        case (false, false): "Make Cartoon Animation"
        }
    }

    private var busy: Bool { source.map { jobs.fraction(.cartoon, for: $0) != nil } ?? true }

    private func load(_ url: URL) {
        guard let picture = ImageFile.load(url) else {
            loadError = "Couldn’t open \(url.lastPathComponent)."
            return
        }
        loadError = nil
        source = url
        image = picture
        result = nil
        player = nil
        previews = [:]
        if picture.extent.width > picture.extent.height * 2.2 { animation = .pan }
        // Draw a small preview of every style.
        Task.detached(priority: .userInitiated) {
            for s in CartoonStyle.allCases {
                if let cg = Cartoonizer.preview(picture, style: s, short: 220) {
                    let ui = UIImage(cgImage: cg)
                    await MainActor.run { if source == url { previews[s] = ui } }
                }
            }
        }
    }

    private func make() {
        guard let source, let image else { return }
        let movie = Cartoonizer.Movie(style: style, animation: animation, resolution: resolution,
                                      seconds: seconds, codec: .current)
        result = nil
        jobs.cartoon(source: source, image: image, movie: movie, library: library) { url in
            result = url
            player = url.pathExtension == "mp4" ? AVPlayer(url: url) : nil
            player?.play()
        }
    }
}

/// A photo from the Photos app, copied to a temporary file.
struct PickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedImage(url: target)
        }
    }
}

/// A video from the Photos app, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

/// Picks one of Econo Camera's own photos, panoramas or cartoon pictures.
struct PicturePicker: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let pick: (URL) -> Void

    var body: some View {
        NavigationStack {
            List {
                let pictures = library.items.filter(\.isImage)
                if pictures.isEmpty {
                    ContentUnavailableView("No pictures yet", systemImage: "photo",
                                           description: Text("Take a photo or panorama on the Camera tab."))
                }
                ForEach(pictures) { item in
                    Button { pick(item.url) } label: { MediaRow(item: item) }
                        .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Pick a Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
