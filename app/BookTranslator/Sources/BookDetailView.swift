import SwiftUI

/// Book detail, as in the design: info on the left, the metadata of the file on the right.
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    var onBack: () -> Void
    @State private var metadata: EpubMetadata?
    @State private var confirmRedo = false
    @State private var showLookup = false
    @State private var editing: String?
    @State private var draft = ""

    private var firstOutput: URL? { book.volumes.first.map { URL(fileURLWithPath: $0.output) } }

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            right.frame(width: 340)
        }
        .background(Theme.window)
        .task(id: book.folder + String(model.library.books.count) + (book.updatedAt ?? "")) { await loadMetadata() }
        .sheet(isPresented: $showLookup) {
            if let metadata { MetadataLookupSheet(book: book, current: metadata) { Task { await loadMetadata() } } }
        }
        .confirmationDialog(loc.t("detail.redoConfirm"), isPresented: $confirmRedo) {
            Button(loc.t("detail.redo"), role: .destructive) { model.runMaintenance(folder: book.folder, arguments: ["--redo"]) }
            Button(loc.t("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Left

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: onBack) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)); Text(loc.t("library.back")) }
                        .font(.system(size: 14)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
                header
                volumes
                qa
            }
            .padding(.horizontal, 36).padding(.vertical, 18)
        }
    }

    private func languageName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return Loc.table["langname.\(value)"] != nil ? loc.t("langname.\(value)") : value
    }

    private var header: some View {
        HStack(spacing: 20) {
            CoverView(title: book.title, image: model.library.covers[book.folder], width: 96, height: 138, radius: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.system(size: 23, weight: .semibold))
                Text("\(book.authorName.isEmpty ? "" : book.authorName + " · ")\(loc.volumes(book.volumes.count)) · \(loc.t(book.kind.key)) · \(languageName(book.sourceLanguage)) → \(languageName(book.targetLanguage))")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                Text(loc.t("detail.done", book.updatedDate?.formatted(date: .long, time: .omitted) ?? ""))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.okText)
                HStack(spacing: 8) {
                    Button(loc.t("detail.openBooks")) { if let url = firstOutput { NSWorkspace.shared.open(url) } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(loc.t("detail.reveal")) { if let url = firstOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                        .buttonStyle(GhostButtonStyle()).controlSize(.large)
                    Button(loc.t("detail.redo")) { confirmRedo = true }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accent, bordered: false)).disabled(model.isBusy)
                }.padding(.top, 6)
            }
        }
    }

    private var volumes: some View {
        CardBox {
            VStack(spacing: 0) {
                ForEach(Array(book.volumes.enumerated()), id: \.element.id) { index, volume in
                    HStack(spacing: 12) {
                        Text(book.volumes.count > 1 ? loc.t("detail.volumeN", volume.index) : loc.t("detail.volumeWhole"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(volume.status == "completed" ? loc.t("detail.volDone") : volume.status)
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Button(loc.t("detail.open")) { NSWorkspace.shared.open(URL(fileURLWithPath: volume.output)) }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    if index < book.volumes.count - 1 { Rectangle().fill(Theme.rowLine).frame(height: 1) }
                }
            }
        }
    }

    private var qa: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("detail.qa")).font(.system(size: 13, weight: .semibold))
                Text(book.qaFlagCount == 0 ? loc.t("detail.qaNone") : loc.t("detail.qaSome", book.qaFlagCount))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let report = book.qaReport, !report.isEmpty, book.qaFlagCount > 0 {
                    Button(loc.t("detail.qaOpen")) { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Right: metadata

    private struct Field: Identifiable {
        var id: String
        var label: String
        var value: String
        var note = ""
        var ok: Bool
        var editable = true
    }

    private func has(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }

    private var fields: [Field] {
        guard let m = metadata else { return [] }
        let isId = m.language.lowercased().hasPrefix("id")
        var list: [Field] = [
            Field(id: "title", label: loc.t("meta.title"), value: m.title, note: loc.t("meta.titleNote"), ok: has(m.title)),
            Field(id: "creator", label: loc.t("meta.creator"), value: m.creators.joined(separator: ", "), ok: !m.creators.isEmpty),
            Field(id: "language", label: loc.t("meta.language"), value: isId ? "\(loc.t("lang.id")) (id)" : m.language, ok: has(m.language), editable: false),
        ]
        if book.volumes.count > 1 || has(m.series) {
            let series = has(m.series) ? m.series + (m.seriesIndex.isEmpty ? "" : " · \(loc.t("meta.seriesNote")) \(m.displaySeriesIndex)") : loc.t("meta.seriesNone")
            list.append(Field(id: "series", label: loc.t("meta.series"), value: series, note: has(m.series) || book.volumes.count <= 1 ? "" : loc.t("meta.missingNote"),
                              ok: has(m.series) || book.volumes.count <= 1))
        }
        list += [
            Field(id: "description", label: loc.t("meta.description"), value: has(m.plainDescription) ? m.plainDescription : loc.t("meta.empty"),
                  note: has(m.plainDescription) ? loc.t("meta.descNote") : loc.t("meta.missingNote"), ok: has(m.plainDescription)),
            Field(id: "subject", label: loc.t("meta.subject"), value: m.subjects.joined(separator: ", "), ok: !m.subjects.isEmpty),
            Field(id: "cover", label: loc.t("meta.cover"), value: m.hasCover ? loc.t("meta.attached") : loc.t("meta.missing"), ok: m.hasCover, editable: false),
            Field(id: "date", label: loc.t("meta.date"), value: m.displayDate, ok: has(m.date)),
        ]
        if has(m.source) { list.append(Field(id: "source", label: loc.t("meta.source"), value: m.source, ok: true, editable: false)) }
        return list
    }

    private var right: some View {
        let rows = fields
        let bad = rows.filter { !$0.ok }.count
        let verified = model.verified.contains(book.folder)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(loc.t("detail.metadata")).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !rows.isEmpty {
                    Pill(text: bad == 0 ? loc.t("detail.summary.all") : loc.t("detail.summary.some", rows.count - bad, rows.count, bad),
                         bg: bad == 0 ? Theme.okBg : Theme.warnBg, fg: bad == 0 ? Theme.okText : Theme.warnText, size: 12)
                }
            }
            Text(loc.t("detail.metadataHint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Button { showLookup = true } label: { Label(loc.t("lookup.button"), systemImage: "globe") }
                .buttonStyle(GhostButtonStyle(tint: Theme.accent)).disabled(metadata == nil)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { fieldRow($0) }
                }
            }
            Button { model.toggleVerified(book.folder) } label: {
                Text(verified ? loc.t("detail.verified") : loc.t("detail.verify")).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fill: verified ? Theme.green : Theme.accent))
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0xFAFAFB))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.barLine).frame(width: 1) }
    }

    private func fieldRow(_ f: Field) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: f.ok ? "checkmark" : "exclamationmark")
                .font(.system(size: 8, weight: .black)).foregroundStyle(f.ok ? Color(hex: 0x1E7B34) : Theme.warnIcon)
                .frame(width: 18, height: 18).background(f.ok ? Theme.okBg : Theme.warnBg, in: Circle()).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.label).font(.system(size: 11)).foregroundStyle(Theme.faint)
                if editing == f.id {
                    TextField("", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 13)).lineLimit(1...6)
                    HStack {
                        Button(loc.t("common.cancel")) { editing = nil }.buttonStyle(GhostButtonStyle())
                        Button(model.metadataBusy ? loc.t("detail.saving") : loc.t("detail.save")) { save(f.id) }
                            .buttonStyle(PrimaryButtonStyle(radius: 8)).disabled(model.metadataBusy)
                    }
                } else {
                    Text(f.value.isEmpty ? "—" : f.value).font(.system(size: 13)).lineSpacing(2).lineLimit(f.id == "description" ? 5 : 3)
                        .textSelection(.enabled)
                    if !f.note.isEmpty { Text(f.note).font(.system(size: 11)).foregroundStyle(f.ok ? Theme.faint : Theme.warnIcon) }
                }
            }
            Spacer(minLength: 0)
            if f.editable && editing != f.id {
                Button(loc.t("detail.change")) { draft = initialDraft(f); editing = f.id }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowLine).frame(height: 1) }
    }

    private func initialDraft(_ f: Field) -> String {
        guard let m = metadata else { return "" }
        switch f.id {
        case "title": return m.title
        case "creator": return m.creators.joined(separator: ", ")
        case "series": return m.series
        case "description": return m.plainDescription
        case "subject": return m.subjects.first ?? ""
        case "date": return m.date
        default: return ""
        }
    }

    private func save(_ field: String) {
        let value = draft
        Task {
            if await model.editMetadata(folder: book.folder, field: field, value: value) { editing = nil }
            await loadMetadata()
        }
    }

    private func loadMetadata() async {
        guard let url = firstOutput else { metadata = nil; return }
        metadata = await Task.detached { EpubReader.read(url) }.value
    }
}
