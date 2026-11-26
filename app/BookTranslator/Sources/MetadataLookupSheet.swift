import SwiftUI

/// "Find metadata online": search a catalogue, pick the matching book, choose which fields to take.
struct MetadataLookupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss
    var book: LibraryBook
    var current: EpubMetadata
    var onDone: (_ applied: [String]) -> Void
    var preview: [MetadataCandidate] = []   // test hook: show these results without searching

    init(book: LibraryBook, current: EpubMetadata, onDone: @escaping (_ applied: [String]) -> Void, preview: [MetadataCandidate] = []) {
        self.book = book
        self.current = current
        self.onDone = onDone
        self.preview = preview
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.authorName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "")
        _results = State(initialValue: preview)
    }

    @State private var notes: [LookupError] = []
    @State private var title: String
    @State private var author: String
    @State private var results: [MetadataCandidate]
    @State private var selected: MetadataCandidate.ID?
    @State private var chosen: Set<String> = []
    @State private var searching = false
    @State private var message = ""
    @State private var applying = false
    @State private var applyErrors: [String] = []

    private var candidate: MetadataCandidate? { results.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                resultsColumn.frame(width: 340)
                Rectangle().fill(Theme.divider).frame(width: 1)
                fieldsColumn.frame(maxWidth: .infinity)
            }
            footer
        }
        .frame(width: 860, height: 580).background(Theme.card)
        .task {
            if preview.isEmpty { await search() } else if let first = preview.first { select(first) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("lookup.title")).font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            Text(loc.t("lookup.hint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            if let isbn = current.isbn {
                Label(loc.t("lookup.isbnUsed", isbn), systemImage: "barcode").font(.system(size: 12)).foregroundStyle(Theme.accentDark)
            }
            HStack(spacing: 8) {
                TextField(loc.t("lookup.titleField"), text: $title).textFieldStyle(.roundedBorder)
                TextField(loc.t("lookup.authorField"), text: $author).textFieldStyle(.roundedBorder).frame(width: 220)
                Button(searching ? loc.t("lookup.searching") : loc.t("lookup.search")) { Task { await search() } }
                    .buttonStyle(PrimaryButtonStyle(radius: 8)).disabled(searching || title.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button { NSWorkspace.shared.open(MetadataLookup.amazonSearchURL(title: title, author: author)) } label: {
                    Label("Amazon", systemImage: "arrow.up.right")
                }.buttonStyle(GhostButtonStyle()).help(loc.t("lookup.amazonHelp"))
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    // MARK: - Results

    private var resultsColumn: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !message.isEmpty {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.warnText).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Theme.warnBg, in: RoundedRectangle(cornerRadius: 10))
                } else if results.isEmpty && !searching {
                    Text(loc.t("lookup.empty")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(20)
                }
                if !results.isEmpty, notes.contains(.isbnMissed) {
                    Text(loc.t("lookup.isbnMissed")).font(.system(size: 11)).foregroundStyle(Theme.warnText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !results.isEmpty, notes.contains(.needsKey) {
                    Text(loc.t("lookup.keyNote")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(results) { item in
                    let on = item.id == selected
                    Button { select(item) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            RemoteImage(urls: CoverFetcher.sources(for: item), title: item.title, width: 44, height: 64, radius: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(item.authors.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                                Text([item.publisher, String(item.date.prefix(4))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                                badge(item)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? Theme.selectedFill : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.accent : Theme.unselectedBorder, lineWidth: on ? 1.5 : 1))
                    }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func badge(_ item: MetadataCandidate) -> some View {
        if item.combined {
            Pill(text: loc.t("lookup.combined", item.sources.map(\.label).joined(separator: " + ")), bg: Theme.fictionBg, fg: Theme.accentDark)
        } else if item.matchedByISBN {
            Pill(text: loc.t("lookup.byISBN"), bg: Theme.okBg, fg: Theme.okText)
        } else {
            Pill(text: "\(loc.t("lookup.byTitle")) · \(item.sources.first?.label ?? "")", bg: Theme.neutralBg, fg: Theme.neutralText)
        }
    }

    // MARK: - Fields

    private struct Row: Identifiable {
        var id: String
        var label: String
        var old: String
        var new: String
        var note = ""
    }

    private var rows: [Row] {
        guard let c = candidate else { return [] }
        var list: [Row] = []
        func add(_ id: String, _ key: String, old: String, new: String, note: String = "") {
            if !new.isEmpty { list.append(Row(id: id, label: loc.t(key), old: old, new: new, note: note)) }
        }
        add("creator", "meta.creator", old: current.creators.joined(separator: ", "), new: c.authors.joined(separator: ", "))
        add("publisher", "meta.publisher", old: current.publisher, new: c.publisher)
        add("date", "meta.date", old: current.displayDate, new: c.date)
        add("subject", "meta.subject", old: current.subjects.joined(separator: ", "), new: c.subjects.joined(separator: ", "))
        add("isbn", "meta.isbn", old: "", new: c.isbn)
        if !CoverFetcher.sources(for: c).isEmpty { add("cover", "meta.cover", old: current.hasCover ? loc.t("meta.attached") : loc.t("meta.missing"), new: loc.t("lookup.coverFound")) }
        add("description", "meta.description", old: current.plainDescription, new: c.description, note: loc.t("lookup.descriptionNote"))
        return list
    }

    private var fieldsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if candidate == nil {
                    Text(loc.t("lookup.pick")).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 30).frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        coverBox(title: loc.t("lookup.yourCover")) {
                            CoverView(title: book.title, image: model.library.covers[book.folder], width: 96, height: 138, radius: 5)
                        }
                        coverBox(title: loc.t("lookup.foundCover")) {
                            RemoteImage(urls: candidate.map { CoverFetcher.sources(for: $0) } ?? [], title: candidate?.title ?? "", width: 96, height: 138, radius: 5)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if let c = candidate {
                                Text(c.title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                                Text(c.authors.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                Text([c.publisher, c.date].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                if !c.isbn.isEmpty { Text("ISBN \(c.isbn)").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                                badge(c).padding(.top, 2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 8)
                    Text(loc.t("lookup.fields")).font(.system(size: 13, weight: .semibold))
                    Text(loc.t("lookup.titleKept")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 6)
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(get: { chosen.contains(row.id) },
                                                     set: { if $0 { chosen.insert(row.id) } else { chosen.remove(row.id) } }))
                                .labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label).font(.system(size: 11)).foregroundStyle(Theme.faint)
                                if !row.old.isEmpty && row.old != row.new {
                                    Text(row.old).font(.system(size: 12)).foregroundStyle(Theme.muted).strikethrough().lineLimit(2)
                                }
                                Text(row.new).font(.system(size: 13)).lineLimit(row.id == "description" ? 5 : 3)
                                if !row.note.isEmpty { Text(row.note).font(.system(size: 11)).foregroundStyle(Theme.warnIcon) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowLine).frame(height: 1) }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !applyErrors.isEmpty {
                Text(loc.t("lookup.applyFailed", applyErrors.joined(separator: " · "))).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(3)
            }
            if let page = candidate?.pageURL {
                Button(loc.t("lookup.openPage")) { NSWorkspace.shared.open(page) }.buttonStyle(.link).font(.system(size: 12))
            }
            Spacer()
            Button(loc.t("common.cancel")) { dismiss() }.buttonStyle(GhostButtonStyle()).controlSize(.large)
            Button(applying ? loc.t("detail.saving") : loc.t("lookup.apply", chosen.count)) { Task { await apply() } }
                .buttonStyle(PrimaryButtonStyle(radius: 8)).disabled(chosen.isEmpty || applying)
                .opacity(chosen.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func coverBox<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 5) {
            content()
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: - Actions

    private func search() async {
        searching = true; message = ""; results = []; selected = nil; chosen = []; notes = []
        defer { searching = false }
        let outcome = await MetadataLookup.identify(isbn: current.isbn, title: title, author: author, googleKey: Secrets.googleBooksKey)
        results = outcome.records
        notes = outcome.notes
        if let first = results.first { select(first) }
        else if outcome.notes.contains(where: { if case .network = $0 { return true } else { return false } }) {
            message = loc.t("lookup.failed", outcome.notes.compactMap { $0.errorDescription }.first ?? "")
        } else { message = loc.t("lookup.none") }
    }

    /// Default: take what is found for fields that are empty now; never overwrite by default.
    private func select(_ item: MetadataCandidate) {
        selected = item.id
        chosen = Set(rows.filter { row in
            switch row.id {
            case "description": return false
            case "cover": return !current.hasCover
            default: return row.old.isEmpty
            }
        }.map(\.id))
    }

    private func apply() async {
        guard let c = candidate else { return }
        applying = true
        applyErrors = []
        defer { applying = false }
        var applied: [String] = []
        for row in rows where chosen.contains(row.id) {
            var value = row.new
            switch row.id {
            case "creator": value = c.authors.joined(separator: "|")
            case "subject": value = c.subjects.joined(separator: "|")
            case "date": value = MetadataLookup.isoDate(c.date)
            case "cover":
                guard let file = await MetadataLookup.downloadCover(for: c) else {
                    applyErrors.append("\(row.label): \(loc.t("lookup.coverMissing"))")
                    continue
                }
                value = file.path
            default: break
            }
            if let error = await model.editMetadata(folder: book.folder, field: row.id, value: value) {
                applyErrors.append("\(row.label): \(String(error.suffix(160)))")
            } else {
                applied.append(row.label)
            }
        }
        onDone(applied)
        if applyErrors.isEmpty { dismiss() }   // stay open when something failed, so the reason can be read
    }
}
