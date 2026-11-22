import AVKit
import QuickLookThumbnailing
import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Repository.self) private var repository
    @State private var filter: MediaKind?
    @State private var showHelp = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    RepositoryView()
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Repository")
                            Text("\(repository.items.count) kept for later · \(SizeText.bytes(repository.totalSize))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                }
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        chip(nil, "All")
                        ForEach(MediaKind.allCases) { chip($0, $0.rawValue) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } footer: {
                Text("\(library.items.count) files using \(SizeText.bytes(library.totalBytes)). Also in \(Library.filesHint).")
            }

            let items = library.items(filter)
            if items.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: filter?.symbol ?? "tray",
                                       description: Text("Take videos, photos and panoramas on the Camera tab."))
            }
            ForEach(items) { item in
                NavigationLink(value: item) { MediaRow(item: item) }
            }
            .onDelete { offsets in
                for index in offsets { library.delete(items[index]) }
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: MediaItem.self) { MediaDetailView(item: $0) }
        .refreshable { library.refresh() }
        .toolbar {
            Button { showHelp = true } label: { Label("How It Works", systemImage: "questionmark.circle") }
        }
        .sheet(isPresented: $showHelp) { HowItWorksView() }
        .onAppear { library.refresh() }
    }

    private func chip(_ kind: MediaKind?, _ title: String) -> some View {
        Button { filter = kind } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(filter == kind ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(filter == kind ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.url)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2).font(.subheadline)
                HStack(spacing: 6) {
                    Image(systemName: item.symbol)
                    Text(item.kind.rawValue)
                    Text("·")
                    Text(SizeText.bytes(item.size)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A small picture of any file (video frame, photo, text page…).
struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            if image == nil, ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) {
                image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 240, height: 240)) }.value
            }
        }
    }
}

struct MediaDetailView: View {
    let item: MediaItem
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var text = ""
    @State private var info = ""
    @State private var smaller = Resolution.p120
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var made: URL?
    @State private var savingToRepository = false

    var body: some View {
        List {
            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                LabeledContent("Size on phone", value: SizeText.bytes(item.size))
                if !info.isEmpty { LabeledContent("Picture", value: info) }
            }

            if item.isImage {
                Section("Cartoon") {
                    Button {
                        navigation.cartoonSource = item.url
                        navigation.tab = .cartoon
                    } label: {
                        Label("Turn into a Cartoon Animation", systemImage: "theatermasks")
                    }
                }
            }

            if item.isVideo || item.isAudio {
                Section("Make") {
                    if item.isVideo {
                        Picker("Smaller copy", selection: $smaller) {
                            ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                        }
                        Button { jobs.mp4(source: item.url, resolution: smaller, library: library) { made = $0 } } label: {
                            Label("Make \(smaller.label) MP4", systemImage: "film")
                        }
                        .disabled(jobs.fraction(.mp4, for: item.url) != nil)
                        if let value = jobs.fraction(.mp4, for: item.url) { ProgressView(value: value) }
                    }
                    Button { jobs.mp3(source: item.url, library: library) { made = $0 } } label: {
                        Label("Make MP3 (sound only)", systemImage: "music.note")
                    }
                    .disabled(jobs.fraction(.mp3, for: item.url) != nil)
                    if let value = jobs.fraction(.mp3, for: item.url) { ProgressView(value: value) }

                    Button { jobs.text(source: item.url, library: library) { result, url in text = result; made = url } } label: {
                        Label("Turn Speech into Text", systemImage: "text.bubble")
                    }
                    .disabled(jobs.fraction(.text, for: item.url) != nil)
                    if let value = jobs.fraction(.text, for: item.url) {
                        ProgressView(value: value) { Text("Listening… (on this device)").font(.caption) }
                    }
                    if let error = jobs.errors[item.url] { Text(error).foregroundStyle(.red) }
                    if let made { FileRow(url: made, repositoryButton: true) }
                }
                if !text.isEmpty && !item.isText {
                    Section("Text") {
                        Text(text).textSelection(.enabled)
                        Button("Copy Text") { UIPasteboard.general.string = text }
                    }
                }
            }

            Section {
                Button { savingToRepository = true } label: {
                    Label("Save to Repository…", systemImage: "archivebox")
                }
                ShareLink(item: item.url) { Label("Share or Save to Files…", systemImage: "square.and.arrow.up") }
                if item.isVideo || item.isImage {
                    Button { Task { await library.saveToPhotos(item.url) } } label: {
                        Label("Save a Copy to Photos", systemImage: "photo.on.rectangle")
                    }
                }
                Button { newName = item.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $savingToRepository) { SaveToRepositorySheet(item: item) }
        .task { await load() }
        .onDisappear { player?.pause() }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { library.rename(item, to: newName); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(item.url.lastPathComponent)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.delete(item); dismiss() }
        }
    }

    @ViewBuilder private var preview: some View {
        if item.isVideo || item.isAudio {
            PlayerView(player: player)
                .frame(height: item.isAudio ? 80 : 320)
                .background(.black)
        } else if item.isImage {
            if item.kind == .pano {
                ScrollView(.horizontal) {
                    AsyncPicture(url: item.url).frame(height: 260)
                }
            } else {
                AsyncPicture(url: item.url).frame(maxHeight: 420)
            }
        } else if item.isText {
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private func load() async {
        if item.isVideo || item.isAudio {
            player = AVPlayer(url: item.url)
            if let size = await Library.videoSize(of: item.url) {
                let seconds = await Library.duration(of: item.url)
                info = "\(Int(size.width))×\(Int(size.height)), \(TimeText.clock(seconds))"
            }
        } else if item.isImage, let image = ImageFile.load(item.url) {
            info = "\(Int(image.extent.width))×\(Int(image.extent.height))"
        } else if item.isText {
            text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        }
    }
}

struct AsyncPicture: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.medium).scaledToFit()
            } else {
                ProgressView().frame(height: 200)
            }
        }
        .task(id: url) { image = UIImage(contentsOfFile: url.path) }
    }
}

/// Plays a video with AVKit's own player (SwiftUI's VideoPlayer is avoided).
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
