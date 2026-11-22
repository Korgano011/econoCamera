import AVKit
import SwiftUI

/// The instructions, read from HowItWorks.txt in the app (the same text as
/// "Econo Camera - How It Works.txt"), shown as readable sections.
struct HowItWorksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [HelpSection] = HelpSection.load()
    @State private var player: AVPlayer?
    @State private var sampleName = "60p sample"

    private var sampleURL: URL? { Bundle.main.url(forResource: sampleName, withExtension: "mp4") }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        samples
                        if let intro = sections.first, intro.title.isEmpty {
                            blocks(intro.blocks)
                        }
                        // Jump list
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Contents").font(.headline)
                            ForEach(sections.filter { !$0.title.isEmpty }) { section in
                                Button(section.displayTitle) {
                                    withAnimation { proxy.scrollTo(section.id, anchor: .top) }
                                }
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                        ForEach(sections.filter { !$0.title.isEmpty }) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.displayTitle)
                                    .font(.title3.bold())
                                    .padding(.top, 10)
                                blocks(section.blocks)
                            }
                            .id(section.id)
                        }
                        acknowledgements
                    }
                    .padding()
                    .textSelection(.enabled)
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if player == nil, let url = sampleURL { player = AVPlayer(url: url) }
            }
            .onChange(of: sampleName) {
                player?.pause()
                player = sampleURL.map { AVPlayer(url: $0) }
            }
            .onDisappear { player?.pause() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if let url = Bundle.main.url(forResource: "HowItWorks", withExtension: "txt") {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }

    /// The two bundled sample videos ("60p sample.mp4" / "240p sample.mp4",
    /// filmed with Econo Camera) with a picker to compare them.
    private var samples: some View {
        VStack(spacing: 10) {
            Text("Sample Videos").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Sample", selection: $sampleName) {
                Text("60p sample").tag("60p sample")
                Text("240p sample").tag("240p sample")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            if sampleURL != nil {
                PlayerView(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if let size = sampleSize {
                    Text("About 10 seconds · \(size)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("The sample video is missing", systemImage: "film")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sampleSize: String? {
        guard let url = sampleURL,
              let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Credit for the bundled LAME encoder, with its LGPL licence text (bundled from LAME/).
    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Acknowledgements").font(.title3.bold()).padding(.top, 10)
            Text("MP3 files are made with the LAME MP3 encoder (lame.sourceforge.io), used under the GNU Lesser General Public License.")
                .font(.callout).foregroundStyle(.secondary)
            if let text = Self.lameLicense {
                DisclosureGroup("LAME licence") {
                    ScrollView {
                        Text(text)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                }
                .font(.callout)
            }
        }
    }

    private static let lameLicense: String? = Bundle.main
        .url(forResource: "LAME License (LGPL)", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    @ViewBuilder private func blocks(_ blocks: [HelpBlock]) -> some View {
        ForEach(blocks) { block in
            switch block.kind {
            case .subheading:
                Text(block.text).font(.headline).padding(.top, 4)
            case .paragraph:
                Text(block.text)
            case .item:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(block.marker).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(block.text)
                }
                .padding(.leading, CGFloat(block.indent) * 14)
            case .table:
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(block.text).font(.system(.caption, design: .monospaced))
                }
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct HelpBlock: Identifiable {
    enum Kind { case subheading, paragraph, item, table }
    let id = UUID()
    var kind: Kind
    var text: String
    var marker = ""
    var indent = 0
}

struct HelpSection: Identifiable {
    let id = UUID()
    var title: String
    var blocks: [HelpBlock] = []

    /// "CAMERA TAB" → "Camera Tab"; keeps sizes like 60p as they are.
    var displayTitle: String {
        title.split(separator: " ").map { word in
            let w = String(word)
            if w.first?.isNumber == true || w.hasPrefix("(") && w.dropFirst().first?.isNumber == true { return w.lowercased() }
            if ["MP3", "MP4", "&", "—"].contains(w) { return w }
            return w.prefix(1) + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func load() -> [HelpSection] {
        guard let url = Bundle.main.url(forResource: "HowItWorks", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [HelpSection(title: "", blocks: [HelpBlock(kind: .paragraph, text: "The instructions are missing.")])]
        }
        return parse(text)
    }

    /// Reads the plain-text layout: titles sit between dashed lines, blank
    /// lines separate paragraphs, "1." and "-" start list items, and
    /// indented blocks with column spacing are tables.
    static func parse(_ text: String) -> [HelpSection] {
        var lines = text.components(separatedBy: "\n")
        // Drop the document title and its === underline.
        if lines.count > 1, lines[1].hasPrefix("===") { lines.removeFirst(2) }

        var sections = [HelpSection(title: "")]
        var paragraph: [String] = []
        var item: HelpBlock?
        var table: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                let joined = paragraph.joined(separator: " ")
                let isSub = paragraph.count == 1 && joined == joined.uppercased() && joined.count > 3
                    && joined.rangeOfCharacter(from: .letters) != nil
                sections[sections.count - 1].blocks.append(HelpBlock(kind: isSub ? .subheading : .paragraph,
                                                                     text: isSub ? joined.capitalized : joined))
                paragraph = []
            }
            if let current = item { sections[sections.count - 1].blocks.append(current); item = nil }
            if !table.isEmpty {
                let indent = table.map { $0.prefix { $0 == " " }.count }.min() ?? 0
                sections[sections.count - 1].blocks.append(
                    HelpBlock(kind: .table, text: table.map { String($0.dropFirst(indent)) }.joined(separator: "\n")))
                table = []
            }
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A section title: ----- / TITLE / -----
            if trimmed.hasPrefix("-----"), index + 2 < lines.count,
               lines[index + 2].trimmingCharacters(in: .whitespaces).hasPrefix("-----") {
                flush()
                sections.append(HelpSection(title: lines[index + 1].trimmingCharacters(in: .whitespaces)))
                index += 3
                continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }

            let leading = line.prefix { $0 == " " }.count
            let isTableLine = leading >= 3 && (trimmed.contains("   ") || trimmed.hasPrefix("----")
                                               || (leading >= 5 && trimmed.contains("  "))
                                               || (!table.isEmpty && leading >= 5))
            if isTableLine && !trimmed.hasPrefix("- ") {
                if item != nil || !paragraph.isEmpty { flush() }
                table.append(line)
                index += 1
                continue
            } else if !table.isEmpty {
                flush()
            }

            if let marker = listMarker(trimmed) {
                flush()
                item = HelpBlock(kind: .item, text: String(trimmed.dropFirst(marker.count + 1)),
                                 marker: marker == "-" ? "•" : marker, indent: leading >= 3 ? 1 : 0)
            } else if var current = item {
                current.text += " " + trimmed
                item = current
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return sections
    }

    private static func listMarker(_ line: String) -> String? {
        if line.hasPrefix("- ") { return "-" }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return digits + "." }
        return nil
    }
}
