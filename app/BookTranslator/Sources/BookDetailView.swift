import SwiftUI

/// One finished book: its volumes and, on the right, the metadata of the file to verify.
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    @State private var metadata: EpubMetadata?
    @State private var confirmRedo = false

    private var firstOutput: URL? {
        book.volumes.first.map { URL(fileURLWithPath: $0.output) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                volumes
                qa
                Divider()
                metadataPanel
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: book.folder) { await loadMetadata() }
        .confirmationDialog(loc.t("detail.redoConfirm"), isPresented: $confirmRedo) {
            Button(loc.t("detail.redo"), role: .destructive) {
                model.runMaintenance(folder: book.folder, arguments: ["--redo"])
            }
            Button(loc.t("common.cancel"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverTile(title: book.title, image: model.library.covers[book.folder], width: 84)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.custom("Georgia", size: 24).weight(.semibold))
                Text(book.authorName).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    KindChip(kind: book.kind)
                    Chip(text: "\(book.sourceLanguage ?? "") → \(book.targetLanguage ?? "")")
                    Chip(text: loc.t("detail.done", finishedText), tint: .green)
                }
            }
        }
    }

    private var finishedText: String {
        guard let date = book.updatedDate else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var actions: some View {
        HStack {
            Button { if let url = firstOutput { NSWorkspace.shared.open(url) } } label: {
                Label(loc.t("detail.openBooks"), systemImage: "book")
            }.buttonStyle(.borderedProminent)
            Button { if let url = firstOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) } } label: {
                Label(loc.t("detail.reveal"), systemImage: "folder")
            }
            Button { confirmRedo = true } label: { Label(loc.t("detail.redo"), systemImage: "arrow.clockwise") }
                .disabled(model.isBusy)
        }
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if book.volumes.count > 1 {
                Text(loc.t("detail.volumes")).font(.headline)
                ForEach(book.volumes) { volume in
                    HStack {
                        Text("\(volume.index)").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 24)
                        Text(volume.title ?? volume.label).lineLimit(1)
                        Spacer()
                        if (volume.metadataMissing ?? []).isEmpty == false { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                        Button(loc.t("detail.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: volume.output)) }
                            .controlSize(.small)
                    }
                    .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var qa: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("detail.qa")).font(.headline)
            Text(book.qaFlagCount == 0 ? loc.t("detail.qaNone") : loc.t("detail.qaSome", book.qaFlagCount))
                .foregroundStyle(.secondary)
            if let report = book.qaReport, !report.isEmpty {
                Button(loc.t("detail.qaOpen")) { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - Metadata

    private struct Field: Identifiable {
        var id: String
        var label: String
        var value: String
        var note: String = ""
        var ok: Bool
    }

    private var fields: [Field] {
        guard let m = metadata else { return [] }
        func has(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }
        let lang = m.language.lowercased().hasPrefix("id") ? loc.t("lang.id") : (m.language.lowercased().hasPrefix("en") ? loc.t("lang.en") : m.language)
        var list = [
            Field(id: "title", label: loc.t("meta.title"), value: m.title, note: loc.t("meta.titleNote"), ok: has(m.title)),
            Field(id: "creator", label: loc.t("meta.creator"), value: m.creators.joined(separator: ", "), ok: !m.creators.isEmpty),
            Field(id: "language", label: loc.t("meta.language"), value: lang,
                  note: m.language.lowercased().hasPrefix("id") ? loc.t("meta.languageNote") : "", ok: has(m.language)),
            Field(id: "description", label: loc.t("meta.description"), value: m.description, ok: has(m.description)),
            Field(id: "publisher", label: loc.t("meta.publisher"), value: m.publisher, ok: has(m.publisher)),
            Field(id: "date", label: loc.t("meta.date"), value: m.date, ok: has(m.date)),
            Field(id: "subject", label: loc.t("meta.subject"), value: m.subjects.joined(separator: ", "), ok: !m.subjects.isEmpty),
            Field(id: "identifier", label: loc.t("meta.identifier"), value: m.identifier, ok: has(m.identifier)),
            Field(id: "cover", label: loc.t("meta.cover"), value: m.hasCover ? loc.t("meta.present") : loc.t("meta.missing"), ok: m.hasCover),
        ]
        if book.volumes.count > 1 {
            list.insert(Field(id: "series", label: loc.t("meta.series"),
                              value: [m.series, m.seriesIndex.isEmpty ? "" : "#\(m.seriesIndex)"].filter { !$0.isEmpty }.joined(separator: " "),
                              ok: has(m.series)), at: 3)
        }
        if has(m.source) { list.append(Field(id: "source", label: loc.t("meta.source"), value: m.source, ok: true)) }
        return list
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("detail.metadata")).font(.headline)
            Text(loc.t("detail.metadataHint")).font(.caption).foregroundStyle(.secondary)
            let rows = fields
            let bad = rows.filter { !$0.ok }.count
            if !rows.isEmpty {
                HStack {
                    Image(systemName: bad == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Text(bad == 0 ? loc.t("detail.complete", rows.count) : loc.t("detail.incomplete", bad, rows.count))
                    Spacer()
                    if bad > 0 {
                        Button(loc.t("detail.fix")) { model.runMaintenance(folder: book.folder, arguments: ["--refresh-metadata"]) }
                            .controlSize(.small).disabled(model.isBusy)
                    }
                }
                .padding(10).font(.callout.weight(.medium))
                .foregroundStyle(bad == 0 ? Color.green : Theme.warnText)
                .background(bad == 0 ? Theme.okBackground : Theme.warnBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(rows) { field in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: field.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(field.ok ? Color.green : Color.red).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        Text(field.value.isEmpty ? "—" : field.value).textSelection(.enabled).lineLimit(field.id == "description" ? 6 : 2)
                        if !field.note.isEmpty { Text(field.note).font(.caption).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }

    private func loadMetadata() async {
        guard let url = firstOutput else { metadata = nil; return }
        metadata = await Task.detached { EpubReader.read(url) }.value
    }
}
