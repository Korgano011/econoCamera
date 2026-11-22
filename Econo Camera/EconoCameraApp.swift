import SwiftUI

@main
struct EconoCameraApp: App {
    @State private var library = Library()
    @State private var jobs = Jobs()
    @State private var camera = CameraModel()
    @State private var repository = Repository()

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(jobs)
                .environment(camera)
                .environment(repository)
                .onAppear { camera.library = library }
        }
    }
}

/// Which tab is showing, and something for the Cartoon tab to start with.
@Observable final class Navigation {
    enum Tab: Hashable { case camera, cartoon, library, convert, text }
    var tab: Tab = .camera
    var cartoonSource: URL?
    var convertSource: URL?
    var textSource: URL?
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(CameraModel.self) private var camera
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = Navigation()
    @State private var showHelp = false
    @State private var showRepository = false
    @Environment(Repository.self) private var repository

    var body: some View {
        @Bindable var library = library
        TabView(selection: $navigation.tab) {
            Tab("Camera", systemImage: "camera", value: .camera) {
                CameraView()
            }
            Tab("Cartoon", systemImage: "theatermasks", value: .cartoon) {
                NavigationStack { CartoonView() }
            }
            Tab("Library", systemImage: "square.grid.2x2", value: .library) {
                NavigationStack { LibraryView() }
            }
            Tab("Convert", systemImage: "arrow.triangle.2.circlepath", value: .convert) {
                NavigationStack { ConverterView() }
            }
            Tab("Text", systemImage: "text.bubble", value: .text) {
                NavigationStack { AudioToTextView() }
            }
        }
        .environment(navigation)
        .sheet(isPresented: $showHelp) { HowItWorksView() }
        .sheet(isPresented: $showRepository) { NavigationStack { RepositoryView() } }
        #if DEBUG
        .onAppear {
            // Screenshots in the Simulator: EC_TAB=cartoon|library|convert|text, EC_CARTOON=<picture path>.
            let env = ProcessInfo.processInfo.environment
            switch env["EC_TAB"] {
            case "cartoon": navigation.tab = .cartoon
            case "library": navigation.tab = .library
            case "convert": navigation.tab = .convert
            case "text": navigation.tab = .text
            default: break
            }
            if env["EC_HELP"] != nil { showHelp = true }
            if env["EC_REPO"] != nil {
                // Saves the newest photo (with its text, if any) and shows the repository.
                if let photo = library.items.first(where: { $0.kind == .photo }) {
                    repository.save(photo, including: repository.companions(of: photo, in: library),
                                    note: "Test street for the cartoon styles")
                }
                showRepository = true
            }
            if let name = env["EC_CARTOON"] { navigation.cartoonSource = Library.root.appendingPathComponent(name) }
        }
        #endif
        .onChange(of: navigation.tab) { _, tab in
            if tab == .camera { Task { await camera.start() } } else { camera.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, navigation.tab == .camera { Task { await camera.start() } }
            if phase == .background { camera.stop() }
            if phase == .active { library.refresh() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.lastError != nil },
                                                            set: { if !$0 { library.lastError = nil } })) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
    }
}

/// Picks one of the five sizes.
struct ResolutionPicker: View {
    @Binding var selection: Resolution

    var body: some View {
        Picker("Size", selection: $selection) {
            ForEach(Resolution.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// A row with a file's name and size, plus Share.
struct FileRow: View {
    let url: URL
    var repositoryButton = false
    @Environment(Library.self) private var library
    @State private var saving: MediaItem?

    var body: some View {
        HStack {
            Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
            Spacer()
            Text(SizeText.bytes(Library.size(of: url))).foregroundStyle(.secondary).monospacedDigit()
            if repositoryButton {
                Button { library.refresh(); saving = library.item(for: url) } label: { Image(systemName: "archivebox") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Save to Repository")
            }
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        }
        .sheet(item: $saving) { SaveToRepositorySheet(item: $0) }
    }
}

/// Copies a picked file somewhere the app can always read it (files from
/// the Files app are only lent while being picked).
enum PickedFile {
    static func localCopy(of url: URL) -> URL? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
