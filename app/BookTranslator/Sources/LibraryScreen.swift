import SwiftUI

/// Step 3: the finished books as a personal library, with the selected book's detail on the right.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @State private var query = ""
    @State private var group = LibraryGrouping.kind
    @State private var sort = LibrarySort.recent
    @State private var selected: String?

    private var finished: [LibraryBook] { model.library.books.filter { $0.isComplete } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                if finished.isEmpty {
                    Spacer()
                    Text(loc.t("library.none")).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    shelf
                }
            }
            .frame(minWidth: 420)
            if let folder = selected, let book = model.library.book(folder: folder) {
                BookDetailView(book: book).frame(minWidth: 420, idealWidth: 520)
            }
        }
        .onAppear { model.library.reload(env: model.env) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("library.summary", finished.count,
                       finished.filter { $0.kind == .fiction }.count,
                       finished.filter { $0.kind == .nonfiction }.count))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(loc.t("library.search"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker(loc.t("library.group"), selection: $group) {
                    ForEach(LibraryGrouping.allCases, id: \.self) { Text(loc.t("library.group.\($0.rawValue)")).tag($0) }
                }.frame(maxWidth: 200)
                Picker(loc.t("library.sort"), selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text(loc.t("library.sort.\($0.rawValue)")).tag($0) }
                }.frame(maxWidth: 200)
                Spacer()
            }
        }
        .padding(16)
    }

    private var shelf: some View {
        let groups = LibraryArranger.arrange(finished, query: query, group: group, sort: sort, loc: loc)
        return ScrollView {
            if groups.isEmpty {
                Text(loc.t("library.empty")).foregroundStyle(.secondary).padding(40)
            }
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                ForEach(groups) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.label.isEmpty {
                            Text("\(section.label) · \(section.books.count)").font(.headline).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], alignment: .leading, spacing: 18) {
                            ForEach(section.books) { book in
                                Button { selected = book.folder } label: { tile(book) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
    }

    private func tile(_ book: LibraryBook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverTile(title: book.title, image: model.library.covers[book.folder], width: 112)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent, lineWidth: selected == book.folder ? 3 : 0))
            Text(book.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            Text(book.authorName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                KindChip(kind: book.kind)
                if book.missingCount > 0 { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption) }
            }
        }
        .frame(width: 120, alignment: .leading)
    }
}
