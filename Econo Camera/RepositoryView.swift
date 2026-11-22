import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Work kept for future use. Search covers names, notes and text.
struct RepositoryView: View {
    @Environment(Repository.self) private var repository
    @State private var search = ""
    @State private var choosingFolder = false
    /// Items waiting for the person to confirm deleting them.
    @State private var toDelete: [RepositoryItem] = []

    private var shown: [RepositoryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return repository.items }
        return repository.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Saved", value: "\(repository.items.count) · \(SizeText.bytes(repository.totalSize))")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(.caption).foregroundStyle(.secondary)
                    Text(repository.displayPath).font(.subheadline)
                }
                Button("Change Folder…") { choosingFolder = true }
                if repository.folder.isCustom {
                    Button("Use the Econo Camera Folder") { repository.useDefaultFolder() }
                }
            } footer: {
                Text("Pick a folder in iCloud Drive, on a USB drive, or anywhere in the Files app to keep your repository there.")
            }

            if repository.items.isEmpty {
                ContentUnavailableView {
                    Label("Your repository is empty", systemImage: "archivebox")
                } description: {
                    Text("Open something in the Library and tap Save to Repository to keep it here for future use.")
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                Section {
                    ForEach(shown) { item in
                        NavigationLink(value: item) { row(item) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { toDelete = [item] } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { toDelete = [item] } label: {
                                    Label("Delete from Repository", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in toDelete = offsets.map { shown[$0] } }
                } header: {
                    Text("Saved items")
                } footer: {
                    Text("Swipe left on an item to delete it, or tap Edit.")
                }
            }
        }
        .navigationTitle("Repository")
        .toolbar {
            if !repository.items.isEmpty { EditButton() }
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { !toDelete.isEmpty },
                                                                 set: { if !$0 { toDelete = [] } }),
                            titleVisibility: .visible) {
            Button(toDelete.count == 1 ? "Delete" : "Delete \(toDelete.count) Items", role: .destructive) {
                for item in toDelete { repository.remove(item) }
                toDelete = []
            }
            Button("Cancel", role: .cancel) { toDelete = [] }
        } message: {
            Text("The copies in the repository are deleted. Anything still in your Library stays there.")
        }
        .searchable(text: $search, prompt: "Search names, notes and text")
        .navigationDestination(for: RepositoryItem.self) { RepositoryDetailView(item: $0) }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { repository.useFolder(url) }
        }
        .refreshable { repository.refresh() }
        .onAppear { repository.refresh() }
        .alert("Repository", isPresented: Binding(get: { repository.lastError != nil },
                                                  set: { if !$0 { repository.lastError = nil } })) {
            Button("OK") { repository.lastError = nil }
        } message: {
            Text(repository.lastError ?? "")
        }
    }

    private var deleteQuestion: String {
        toDelete.count == 1 ? "Delete “\(toDelete[0].title)” from the repository?"
            : "Delete \(toDelete.count) items from the repository?"
    }

    private func row(_ item: RepositoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let main = item.main { Thumbnail(url: main) } else { Color.secondary.opacity(0.15) }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline).lineLimit(2)
                Text("\(item.savedOn.formatted(date: .abbreviated, time: .shortened)) · \(SizeText.bytes(item.size)) · \(item.files.map { $0.pathExtension.uppercased() }.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                if !item.note.isEmpty {
                    Text(item.note).font(.caption).lineLimit(2)
                }
                if !search.isEmpty, let snippet = snippet(item.transcript) {
                    Text(snippet).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private func snippet(_ text: String) -> String? {
        guard let range = text.range(of: search, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return "…" + text[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
    }
}

struct RepositoryDetailView: View {
    let item: RepositoryItem
    @Environment(Repository.self) private var repository
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var note = ""
    @State private var noteSaved = false
    @State private var copiedBack = false
    @State private var confirmRemove = false

    var body: some View {
        List {
            if let main = item.main {
                Section {
                    preview(main).frame(maxWidth: .infinity).listRowInsets(EdgeInsets())
                }
            }
            Section("Note") {
                TextEditor(text: $note).frame(minHeight: 90)
                Button(noteSaved ? "Note Saved" : "Save Note") {
                    repository.setNote(note, for: item)
                    noteSaved = true
                }
                .disabled(noteSaved || note == item.note)
            }
            Section("Files") {
                ForEach(item.files, id: \.self) { file in
                    HStack {
                        Text(file.lastPathComponent).font(.subheadline).lineLimit(2)
                        Spacer()
                        Text(SizeText.bytes(Library.size(of: file))).font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                    }
                }
            }
            if !item.transcript.isEmpty {
                Section("Text") { Text(item.transcript).font(.callout).textSelection(.enabled) }
            }
            Section {
                Button {
                    repository.restore(item, to: library)
                    copiedBack = true
                } label: {
                    Label(copiedBack ? "Copied to the Library" : "Copy Back to the Library", systemImage: "square.and.arrow.down")
                }
                .disabled(copiedBack)
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Delete from Repository", systemImage: "trash")
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(role: .destructive) { confirmRemove = true } label: {
                Label("Delete from Repository", systemImage: "trash")
            }
        }
        .onAppear {
            note = item.note
            if let main = item.main, ["mp4", "mov", "m4v", "mp3"].contains(main.pathExtension.lowercased()) {
                player = AVPlayer(url: main)
            }
        }
        .onChange(of: note) { noteSaved = false }
        .onDisappear { player?.pause() }
        .confirmationDialog("Delete “\(item.title)” from the repository?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { repository.remove(item); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copies in the repository are deleted. Anything still in your Library stays there.")
        }
    }

    @ViewBuilder private func preview(_ url: URL) -> some View {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": PlayerView(player: player).frame(height: 300).background(.black)
        case "mp3": PlayerView(player: player).frame(height: 80)
        case "jpg", "jpeg", "png", "heic": AsyncPicture(url: url).frame(maxHeight: 360)
        default: EmptyView()
        }
    }
}

/// Asks for an optional note, then saves a Library file to the repository.
struct SaveToRepositorySheet: View {
    let item: MediaItem
    @Environment(Repository.self) private var repository
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var includeExtras = true

    var body: some View {
        let extras = repository.companions(of: item, in: library)
        NavigationStack {
            Form {
                Section {
                    MediaRow(item: item)
                    if !extras.isEmpty {
                        Toggle("Also save its \(extras.map { $0.isText ? "text" : "MP3" }.joined(separator: " and "))",
                               isOn: $includeExtras)
                    }
                }
                Section {
                    TextEditor(text: $note).frame(minHeight: 100)
                } header: {
                    Text("Note (optional)")
                } footer: {
                    Text("Notes are searchable in the repository. Saving to: \(repository.displayPath)")
                }
                if repository.contains(item) {
                    Section {
                        Label("Something with this name is already in the repository. Saving again keeps both.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Save to Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if repository.save(item, including: includeExtras ? extras : [], note: note) { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
