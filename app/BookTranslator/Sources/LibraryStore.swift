import Foundation
import Observation
import AppKit

/// The finished books: every `books/<book>/book.json` the engine wrote.
@MainActor @Observable
final class LibraryStore {
    var books: [LibraryBook] = []
    var covers: [String: NSImage] = [:]
    private var loading = false
    /// Test hook: keep the books as set, ignore rescans.
    var frozen = false

    func reload(env: BackendEnvironment, force: Bool = false) {
        guard !frozen, !loading || force else { return }
        loading = true
        let root = env.booksDir
        Task.detached(priority: .utility) {
            let loaded = LibraryStore.scan(root)
            await MainActor.run {
                self.books = loaded
                self.loading = false
                self.loadCovers(for: loaded, root: root)
            }
        }
    }

    nonisolated static func scan(_ root: URL) -> [LibraryBook] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [LibraryBook] = []
        for folder in folders where folder.lastPathComponent != "inbox" {
            if let book = read(folder: folder) { result.append(book) }
        }
        return result
    }

    nonisolated static func read(folder: URL) -> LibraryBook? {
        let file = folder.appendingPathComponent("book.json")
        guard let data = try? Data(contentsOf: file),
              var book = try? JSONDecoder.snake.decode(LibraryBook.self, from: data) else { return nil }
        book.folder = folder.lastPathComponent
        book.check = CheckReport.read(folder)
        if let first = book.volumes.first(where: { !$0.output.isEmpty && FileManager.default.fileExists(atPath: $0.output) }),
           let meta = EpubReader.read(URL(fileURLWithPath: first.output)) {
            book.authorName = meta.creators.joined(separator: ", ")
            book.series = meta.series
        }
        return book
    }

    private func loadCovers(for books: [LibraryBook], root: URL) {
        for book in books where covers[book.folder] == nil {
            guard let output = book.volumes.first?.output, !output.isEmpty else { continue }
            let folder = book.folder
            Task.detached(priority: .utility) {
                if let image = EpubReader.cover(URL(fileURLWithPath: output)) {
                    await MainActor.run { self.covers[folder] = image }
                }
            }
        }
    }

    /// Forget a cached cover so the next reload reads the new one from the EPUB.
    func dropCover(folder: String) { covers[folder] = nil }

    func book(folder: String) -> LibraryBook? { books.first { $0.folder == folder } }
}

enum LibraryGrouping: String, CaseIterable { case none, series, author, kind }
enum LibrarySort: String, CaseIterable { case recent, title, author }

struct LibraryGroup: Identifiable {
    var id: String
    var label: String
    var books: [LibraryBook]
}

enum LibraryArranger {
    static func arrange(_ books: [LibraryBook], query: String, group: LibraryGrouping, sort: LibrarySort,
                        loc: Loc) -> [LibraryGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var items = books.filter { b in
            q.isEmpty || b.title.lowercased().contains(q) || b.authorName.lowercased().contains(q)
        }
        switch sort {
        case .recent: items.sort { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author: items.sort { $0.authorName.localizedCaseInsensitiveCompare($1.authorName) == .orderedAscending }
        }
        guard !items.isEmpty else { return [] }
        switch group {
        case .none:
            return [LibraryGroup(id: "all", label: "", books: items)]
        case .kind:
            return [BookKind.fiction, .nonfiction].compactMap { kind in
                let rows = items.filter { $0.kind == kind }
                return rows.isEmpty ? nil : LibraryGroup(id: kind.rawValue, label: loc.t(kind.key), books: rows)
            }
        case .series:
            let names = Array(Set(items.map { $0.series })).sorted {
                if $0.isEmpty != $1.isEmpty { return !$0.isEmpty }
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return names.map { name in
                LibraryGroup(id: name, label: name.isEmpty ? loc.t("library.noSeries") : name, books: items.filter { $0.series == name })
            }
        case .author:
            let names = Array(Set(items.map { $0.authorName })).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return names.map { name in
                LibraryGroup(id: name, label: name.isEmpty ? "—" : name, books: items.filter { $0.authorName == name })
            }
        }
    }
}
