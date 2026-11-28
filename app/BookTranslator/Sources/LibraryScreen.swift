import SwiftUI

/// Step 3, as in the design: search, group and sort controls over book cards; opening a card
/// replaces the shelf with the book's detail.
enum LibraryLayoutMode: String, CaseIterable {
    case cards, covers
    var symbol: String { self == .cards ? "rectangle.grid.2x2" : "square.grid.3x3.fill" }
}

struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @State private var query = ""
    @State private var group = LibraryGrouping.kind
    @State private var sort = LibrarySort.recent
    @AppStorage("libraryLayout") private var layout = LibraryLayoutMode.cards
    @Binding var openFolder: String?

    private var finished: [LibraryBook] { model.library.books.filter { $0.isComplete } }

    var body: some View {
        if let folder = openFolder, let book = model.library.book(folder: folder) {
            BookDetailView(book: book) { openFolder = nil }
        } else {
            shelf.onAppear { model.library.reload(env: model.env) }
        }
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            let groups = LibraryArranger.arrange(finished, query: query, group: group, sort: sort, loc: loc)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if finished.isEmpty {
                        Text(loc.t("library.none")).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(60)
                    } else if groups.isEmpty {
                        Text(loc.t("library.empty")).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(groups) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.label.isEmpty {
                                (Text(section.label).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.neutralText)
                                 + Text(" · \(section.books.count)").font(.system(size: 13)).foregroundColor(Theme.faint))
                            }
                            if layout == .covers {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 176), spacing: 24, alignment: .top)],
                                          alignment: .leading, spacing: 26) {
                                    ForEach(section.books) { coverTile($0) }
                                }
                                .padding(.top, 4)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 164), spacing: 14, alignment: .top)],
                                          alignment: .leading, spacing: 14) {
                                    ForEach(section.books) { card($0) }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 40).padding(.top, 20)
        .background(Theme.window)
    }

    // The controls adapt to the window: one row when there is room, two rows when it narrows, and menus
    // instead of segmented controls when it is narrower still. Nothing is allowed to wrap letter by letter.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            fullRow
            twoRows
            menuRow
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
            TextField(loc.t("library.search2"), text: $query).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.fieldBorder))
    }

    private var summary: some View {
        Text(loc.t("library.summary2", finished.count, finished.reduce(0) { $0 + max($1.volumes.count, 1) }))
            .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
    }

    private var groupControl: some View {
        HStack(spacing: 8) {
            Text(loc.t("library.group")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            Segmented(items: LibraryGrouping.allCases.map { ($0, loc.t("library.group.\($0.rawValue)")) }, selection: $group)
        }
    }

    private var sortControl: some View {
        HStack(spacing: 8) {
            Text(loc.t("library.sort")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            Segmented(items: LibrarySort.allCases.map { ($0, loc.t("library.sort.\($0.rawValue)")) }, selection: $sort)
        }
    }

    private var layoutControl: some View {
        IconSegmented(items: LibraryLayoutMode.allCases.map { ($0, $0.symbol, loc.t("library.layout.\($0.rawValue)")) }, selection: $layout)
    }

    private var fullRow: some View {
        HStack(spacing: 14) {
            searchField.frame(width: 240)
            summary
            Spacer(minLength: 8)
            groupControl
            sortControl
            layoutControl
        }
    }

    private var twoRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                searchField.frame(minWidth: 180, maxWidth: 320)
                summary
                Spacer(minLength: 8)
                layoutControl
            }
            HStack(spacing: 18) {
                groupControl
                sortControl
                Spacer(minLength: 0)
            }
        }
    }

    private var menuRow: some View {
        HStack(spacing: 12) {
            searchField.frame(minWidth: 140, maxWidth: 260)
            Picker(loc.t("library.group"), selection: $group) {
                ForEach(LibraryGrouping.allCases, id: \.self) { Text(loc.t("library.group.\($0.rawValue)")).tag($0) }
            }.pickerStyle(.menu).fixedSize()
            Picker(loc.t("library.sort"), selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text(loc.t("library.sort.\($0.rawValue)")).tag($0) }
            }.pickerStyle(.menu).fixedSize()
            Spacer(minLength: 4)
            layoutControl
        }
    }

    /// Missing book details the user has not accepted yet, or a final check that asks for a look.
    private func needsAttention(_ book: LibraryBook) -> Bool {
        (book.missingCount > 0 && !model.verified.contains(book.folder)) || (book.check?.needsLook ?? false)
    }

    private func card(_ book: LibraryBook) -> some View {
        let attention = needsAttention(book)
        return Button { openFolder = book.folder } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverView(title: book.title, image: model.library.covers[book.folder], width: 146, height: 112, showTitle: true, radius: 5)
                    .overlay(alignment: .topLeading) { kindleBadge(book) }
                Text(book.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                Text(book.authorName).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: loc.t(book.isPolishOnly ? "library.polished" : book.kind.key),
                         bg: book.kind.pillBg, fg: book.kind.pillFg)
                    if attention {
                        let failed = book.check?.overall == "fail"
                        Pill(text: loc.t("library.check"), bg: failed ? Theme.dangerBg : Theme.warnBg, fg: failed ? Theme.danger : Theme.warnText)
                    }
                }
            }
            .padding(9).frame(width: 164, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
    }

    /// On a cover: green when the book is on the Kindle, amber when it changed since it was sent.
    @ViewBuilder private func kindleBadge(_ book: LibraryBook) -> some View {
        if book.kindleMark != .none {
            let sent = book.kindleMark == .sent
            Label(loc.t(sent ? "kindle.mark.sent" : "kindle.mark.changed"), systemImage: "paperplane.fill")
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.onAction)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(sent ? Theme.actionPolish : Theme.warnIcon, in: Capsule())
                .padding(6)
        }
    }

    /// Cover-first tile: a large rounded cover with the title, author and volume count under it.
    private func coverTile(_ book: LibraryBook) -> some View {
        let attention = needsAttention(book)
        return Button { openFolder = book.folder } label: {
            VStack(alignment: .leading, spacing: 10) {
                CoverView(title: book.title, image: model.library.covers[book.folder], width: 176, height: 264, showTitle: true, radius: 14)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                    .overlay(alignment: .topLeading) { kindleBadge(book) }
                    .overlay(alignment: .topTrailing) {
                        if attention {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.warnIcon)
                                .background(Circle().fill(Theme.card)).padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(book.authorName).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text([loc.t(book.kind.key), book.volumes.count > 1 ? loc.volumes(book.volumes.count) : "",
                          book.isPolishOnly ? loc.t("library.polished") : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 176, alignment: .leading)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
    }
}
