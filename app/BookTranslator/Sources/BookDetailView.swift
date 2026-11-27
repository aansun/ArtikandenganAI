import SwiftUI

/// Book detail, as in the design: info on the left, the metadata of the file on the right.
struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    var onBack: () -> Void
    @State private var metadata: EpubMetadata?
    @State private var confirmRedo = false
    @State private var deletion: DeletionPlan?
    @State private var showLookup = false
    @State private var editing: String?
    @State private var draft = ""
    @State private var notice: String?
    @State private var editError: String?

    private var firstOutput: URL? { book.volumes.first.map { URL(fileURLWithPath: $0.output) } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            left.frame(width: 330)
            right.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .task(id: book.folder + String(model.library.books.count) + (book.updatedAt ?? "")) { await loadMetadata() }
        .sheet(isPresented: $showLookup) {
            if let metadata {
                MetadataLookupSheet(book: book, current: metadata) { applied in
                    if !applied.isEmpty { notice = loc.t("lookup.applied", applied.joined(separator: ", ")) }
                    Task { await loadMetadata() }
                }
            }
        }
        .sheet(item: $deletion) { plan in
            DeleteBookSheet(book: book, plan: plan) { deleted in
                deletion = nil
                if deleted { onBack() }
            }
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
                CheckCard(book: book)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }

    private func languageName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return Loc.table["langname.\(value)"] != nil ? loc.t("langname.\(value)") : value
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CoverView(title: book.title, image: model.library.covers[book.folder], width: 78, height: 112, radius: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.system(size: 17, weight: .semibold)).lineLimit(3)
                    Text(book.authorName).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                    Text("\(loc.volumes(book.volumes.count)) · \(loc.t(book.kind.key))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text("\(languageName(book.sourceLanguage)) → \(languageName(book.targetLanguage))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(loc.t("detail.done", book.updatedDate?.formatted(date: .abbreviated, time: .omitted) ?? ""))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.okText)
                }
            }
            VStack(spacing: 6) {
                Button { if let url = firstOutput { NSWorkspace.shared.open(url) } } label: {
                    Text(loc.t("detail.openBooks")).frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButtonStyle())
                HStack(spacing: 6) {
                    Button { if let url = firstOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) } } label: {
                        Text(loc.t("detail.reveal")).frame(maxWidth: .infinity)
                    }.buttonStyle(GhostButtonStyle())
                    Button { confirmRedo = true } label: { Text(loc.t("detail.redo")).frame(maxWidth: .infinity) }
                        .buttonStyle(GhostButtonStyle(tint: Theme.accent)).disabled(model.isBusy)
                }
                Button { deletion = model.deletionPlan(book.folder) } label: {
                    Text(loc.t("delete.button")).frame(maxWidth: .infinity)
                }
                .buttonStyle(GhostButtonStyle(tint: Theme.danger)).disabled(!model.canDelete(book.folder))
                .help(model.canDelete(book.folder) ? "" : loc.t("delete.queued"))
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
            Field(id: "publisher", label: loc.t("meta.publisher"), value: m.publisher, note: has(m.publisher) ? "" : loc.t("meta.optional"), ok: true),
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
            Field(id: "isbn", label: loc.t("meta.isbn"), value: m.isbns.joined(separator: ", "), note: m.isbns.isEmpty ? loc.t("meta.optional") : "", ok: true),
        ]
        if has(m.source) { list.append(Field(id: "source", label: loc.t("meta.source"), value: m.source, ok: true, editable: false)) }
        return list
    }

    private var right: some View {
        let rows = fields
        let bad = rows.filter { !$0.ok }.count
        let verified = model.verified.contains(book.folder)
        let wide = rows.filter { $0.id == "description" }
        let grid = rows.filter { $0.id != "description" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(loc.t("detail.metadata")).font(.system(size: 17, weight: .semibold))
                if !rows.isEmpty {
                    Pill(text: bad == 0 ? loc.t("detail.summary.all") : loc.t("detail.summary.some", rows.count - bad, rows.count, bad),
                         bg: bad == 0 ? Theme.okBg : Theme.warnBg, fg: bad == 0 ? Theme.okText : Theme.warnText, size: 12)
                }
                Spacer()
                Button { showLookup = true } label: { Label(loc.t("lookup.button"), systemImage: "globe") }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accent)).disabled(metadata == nil)
            }
            Text(loc.t("detail.metadataHint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.okText).padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.okBg, in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 0) {
                        ForEach(grid) { fieldRow($0) }
                    }
                    ForEach(wide) { fieldRow($0) }
                }
            }
            Button { model.toggleVerified(book.folder) } label: {
                Text(verified ? loc.t("detail.verified") : loc.t("detail.verify")).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fill: verified ? Theme.green : Theme.accent))
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.barLine).frame(width: 1) }
    }

    private func fieldRow(_ f: Field) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: f.ok ? "checkmark" : "exclamationmark")
                .font(.system(size: 8, weight: .black)).foregroundStyle(f.ok ? Theme.green : Theme.warnIcon)
                .frame(width: 18, height: 18).background(f.ok ? Theme.okBg : Theme.warnBg, in: Circle()).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.label).font(.system(size: 11)).foregroundStyle(Theme.faint)
                if editing == f.id {
                    TextField("", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 13)).lineLimit(1...6)
                    if let editError { Text(editError).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(3) }
                    HStack {
                        Button(loc.t("common.cancel")) { editing = nil; editError = nil }.buttonStyle(GhostButtonStyle())
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
        case "publisher": return m.publisher
        case "isbn": return m.isbn ?? ""
        default: return ""
        }
    }

    private func save(_ field: String) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if field == "isbn", !value.isEmpty, ISBN.normalised(value) == nil { editError = loc.t("detail.invalidISBN"); return }
        editError = nil
        Task {
            if let error = await model.editMetadata(folder: book.folder, field: field, value: value) {
                editError = String(error.suffix(200))
            } else {
                editing = nil
                notice = loc.t("lookup.applied", loc.t("meta.\(field == "creator" ? "creator" : field)"))
                await loadMetadata()
            }
        }
    }

    private func loadMetadata() async {
        guard let url = firstOutput else { metadata = nil; return }
        metadata = await Task.detached { EpubReader.read(url) }.value
    }
}
