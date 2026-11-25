import SwiftUI

/// Step 3, as in the design: search, group and sort controls over book cards; opening a card
/// replaces the shelf with the book's detail.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @State private var query = ""
    @State private var group = LibraryGrouping.kind
    @State private var sort = LibrarySort.recent
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
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 164), spacing: 14, alignment: .top)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(section.books) { card($0) }
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

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint)
                TextField(loc.t("library.search2"), text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).padding(.vertical, 6).frame(width: 240)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: 0xD2D2D7)))
            Text(loc.t("library.summary2", finished.count, finished.reduce(0) { $0 + max($1.volumes.count, 1) }))
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Spacer()
            HStack(spacing: 8) {
                Text(loc.t("library.group")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Segmented(items: LibraryGrouping.allCases.map { ($0, loc.t("library.group.\($0.rawValue)")) }, selection: $group)
            }
            HStack(spacing: 8) {
                Text(loc.t("library.sort")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Segmented(items: LibrarySort.allCases.map { ($0, loc.t("library.sort.\($0.rawValue)")) }, selection: $sort)
            }
        }
    }

    private func card(_ book: LibraryBook) -> some View {
        let attention = book.missingCount > 0 && !model.verified.contains(book.folder)
        return Button { openFolder = book.folder } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverView(title: book.title, image: model.library.covers[book.folder], width: 146, height: 112, showTitle: true, radius: 5)
                Text(book.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                Text(book.authorName).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: loc.t(book.kind.key), bg: book.kind.pillBg, fg: book.kind.pillFg)
                    if attention { Pill(text: loc.t("library.check"), bg: Theme.warnBg, fg: Theme.warnText) }
                }
            }
            .padding(9).frame(width: 164, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
    }
}
