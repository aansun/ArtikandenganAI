import SwiftUI

/// Book detail: what can be done with the book on the left, the book and the metadata of its file on the right.
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
    @State private var managing = false         // translate again and delete stay folded until asked for

    private var redoKey: String { book.isPolishOnly ? "detail.repolish" : "detail.redo" }
    private var firstOutput: URL? { book.volumes.first.map { URL(fileURLWithPath: $0.output) } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            left.frame(width: 300)
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
        .confirmationDialog(loc.t(book.isPolishOnly ? "detail.repolishConfirm" : "detail.redoConfirm"), isPresented: $confirmRedo) {
            Button(loc.t(redoKey), role: .destructive) { model.runMaintenance(folder: book.folder, arguments: ["--redo"]) }
            Button(loc.t("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Left: what can be done

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)); Text(loc.t("library.back")) }
                        .font(.system(size: 14)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
                ActionGroup(title: loc.t("group.read")) { reading }
                ActionGroup(title: loc.t("detail.metadata")) { metadataActions }
                CheckCard(book: book).id(book.folder)
                managementActions
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
    }

    /// Where the book can be read: open it here, send it to the Kindle, or find its file.
    /// A longer book has one more row per volume.
    private var reading: some View {
        CardBox {
            VStack(spacing: 0) {
                ActionRow(symbol: "book.fill", image: OfficialIcons.books, title: "Apple Books", help: loc.t("detail.openBooks"),
                          trailing: "arrow.up.forward") { if let url = firstOutput { NSWorkspace.shared.open(url) } }
                rowLine
                KindleCard(book: book)
                rowLine
                ActionRow(symbol: "folder.fill", image: OfficialIcons.finder, title: "Finder", help: loc.t("detail.reveal"),
                          trailing: "arrow.up.forward") {
                    if let url = firstOutput { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if book.volumes.count > 1 {
                    ForEach(book.volumes) { volume in
                        rowLine
                        ActionRow(symbol: volume.status == "completed" ? "checkmark.circle.fill" : "clock",
                                  title: loc.t("detail.volumeN", volume.index),
                                  help: volume.status == "completed" ? loc.t("detail.open") : volume.status,
                                  tint: volume.status == "completed" ? Theme.green : Theme.warnIcon,
                                  trailing: "arrow.up.forward") { NSWorkspace.shared.open(URL(fileURLWithPath: volume.output)) }
                    }
                }
            }
        }
    }

    private var verified: Bool { model.verified.contains(book.folder) }

    /// Everything about the details of the file.
    private var metadataActions: some View {
        CardBox {
            VStack(spacing: 0) {
                ActionRow(symbol: "globe", title: loc.t("detail.lookup.short"), help: loc.t("lookup.button")) { showLookup = true }
                    .disabled(metadata == nil)
                rowLine
                ActionRow(symbol: verified ? "checkmark.seal.fill" : "checkmark.seal",
                          title: loc.t(verified ? "detail.verified.short" : "detail.verify.short"),
                          help: loc.t(verified ? "detail.verified" : "detail.verify"),
                          tint: verified ? Theme.green : Theme.accent) { model.toggleVerified(book.folder) }
            }
        }
    }

    /// What is done rarely, or cannot be undone.
    private var managementActions: some View {
        CardBox {
            VStack(spacing: 0) {
                Button { managing.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.muted)
                        Text(loc.t("group.manage")).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        Image(systemName: managing ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.faint).frame(width: 12)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if managing {
                    rowLine
                    ActionRow(symbol: "arrow.clockwise", title: loc.t(redoKey), help: loc.t(redoKey)) { confirmRedo = true }
                        .disabled(model.isBusy)
                    rowLine
                    ActionRow(symbol: "trash", title: loc.t("delete.button"),
                              help: loc.t(model.canDelete(book.folder) ? "delete.button" : "delete.queued"),
                              tint: Theme.danger) { deletion = model.deletionPlan(book.folder) }
                        .disabled(!model.canDelete(book.folder))
                }
            }
        }
    }

    private var rowLine: some View { Rectangle().fill(Theme.rowLine).frame(height: 1) }

    private func languageName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return Loc.table["langname.\(value)"] != nil ? loc.t("langname.\(value)") : value
    }

    private func fact(_ symbol: String, _ text: String, color: Color = Theme.muted) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(color)
    }

    /// The cover and what the book is, above the metadata of its file.
    private func header(rows: [Field]) -> some View {
        let bad = rows.filter { !$0.ok }.count
        let done = book.updatedDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
        return HStack(alignment: .top, spacing: 18) {
            CoverView(title: book.title, image: model.library.covers[book.folder], width: 96, height: 140, radius: 6)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title).font(.system(size: 21, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                Text(book.authorName).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
                HStack(spacing: 6) {
                    Pill(text: loc.t(book.kind.key), bg: book.kind.pillBg, fg: book.kind.pillFg)
                    if !rows.isEmpty {
                        Label(bad == 0 ? loc.t("detail.summary.all") : loc.t("detail.summary.some", bad),
                              systemImage: bad == 0 ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(bad == 0 ? Theme.okText : Theme.warnText)
                            .padding(.horizontal, 9).padding(.vertical, 2.5)
                            .background(bad == 0 ? Theme.okBg : Theme.warnBg, in: Capsule())
                    }
                }
                HStack(spacing: 14) {
                    fact("globe", book.isPolishOnly ? loc.t("detail.polished", languageName(book.targetLanguage))
                         : "\(languageName(book.sourceLanguage)) → \(languageName(book.targetLanguage))")
                    if book.volumes.count > 1 { fact("books.vertical", loc.volumes(book.volumes.count)) }
                    fact("checkmark.circle.fill", done, color: Theme.okText).help(loc.t("detail.done", done))
                }
            }
            Spacer(minLength: 0)
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
            Field(id: "title", label: loc.t("meta.title"), value: m.title, ok: has(m.title)),
            Field(id: "creator", label: loc.t("meta.creator"), value: m.creators.joined(separator: ", "), ok: !m.creators.isEmpty),
            Field(id: "publisher", label: loc.t("meta.publisher"), value: m.publisher, ok: true),
            Field(id: "language", label: loc.t("meta.language"), value: isId ? "\(loc.t("lang.id")) (id)" : m.language, ok: has(m.language)),
        ]
        if book.volumes.count > 1 || has(m.series) {
            let series = has(m.series) ? m.series + (m.seriesIndex.isEmpty ? "" : " · \(loc.t("meta.seriesNote")) \(m.displaySeriesIndex)") : loc.t("meta.seriesNone")
            list.append(Field(id: "series", label: loc.t("meta.series"), value: series, note: has(m.series) || book.volumes.count <= 1 ? "" : loc.t("meta.missingNote"),
                              ok: has(m.series) || book.volumes.count <= 1))
        }
        list += [
            Field(id: "description", label: loc.t("meta.description"), value: has(m.plainDescription) ? m.plainDescription : loc.t("meta.empty"),
                  note: loc.t("meta.missingNote"), ok: has(m.plainDescription)),
            Field(id: "subject", label: loc.t("meta.subject"), value: m.subjects.joined(separator: ", "), ok: !m.subjects.isEmpty),
            Field(id: "cover", label: loc.t("meta.cover"), value: m.hasCover ? loc.t("meta.attached") : loc.t("meta.missing"), ok: m.hasCover, editable: false),
            Field(id: "date", label: loc.t("meta.date"), value: m.displayDate, ok: has(m.date)),
            Field(id: "isbn", label: loc.t("meta.isbn"), value: m.isbns.joined(separator: ", "), ok: true),
        ]
        if has(m.source) { list.append(Field(id: "source", label: loc.t("meta.source"), value: m.source, ok: true, editable: false)) }
        return list
    }

    private var right: some View {
        let rows = fields
        let wide = rows.filter { $0.id == "description" }
        let grid = rows.filter { $0.id != "description" }
        return VStack(alignment: .leading, spacing: 12) {
            header(rows: rows)
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.okText).padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.okBg, in: RoundedRectangle(cornerRadius: 8))
            }
            Rectangle().fill(Theme.barLine).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 0) {
                        ForEach(grid) { fieldRow($0) }
                    }
                    ForEach(wide) { fieldRow($0) }
                }
            }
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
                    if !f.ok && !f.note.isEmpty { Text(f.note).font(.system(size: 11)).foregroundStyle(Theme.warnIcon) }
                }
            }
            Spacer(minLength: 0)
            if f.editable && editing != f.id {
                IconButton(symbol: "pencil", help: loc.t("detail.change")) { draft = initialDraft(f); editing = f.id }
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
        case "language": return m.language
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
