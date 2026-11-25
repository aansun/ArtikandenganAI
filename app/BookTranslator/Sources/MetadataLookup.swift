import Foundation
import Security

/// One book found online.
struct MetadataCandidate: Identifiable, Equatable {
    var id = UUID()
    var source: MetadataSource
    var title: String
    var authors: [String] = []
    var publisher = ""
    var date = ""
    var description = ""
    var subjects: [String] = []
    var isbn = ""
    var altISBNs: [String] = []   // other editions' ISBNs, for finding a cover
    var coverURL: URL?
    var pageURL: URL?
    /// Which catalogues this record comes from (several for a combined record).
    var sources: [MetadataSource] = []
    var matchedByISBN = false
    var score = 0.0
    var combined = false
}

enum MetadataSource: String, CaseIterable, Identifiable {
    case openLibrary, googleBooks
    var id: String { rawValue }
    var label: String { self == .openLibrary ? "Open Library" : "Google Books" }
}

enum LookupError: LocalizedError, Equatable {
    case needsKey
    case isbnMissed            // the ISBN gave no record (or the catalogue did not answer): title matches follow
    case rejected(String)
    case network(String)
    var errorDescription: String? {
        switch self {
        case .needsKey: return "needsKey"
        case .isbnMissed: return "isbnMissed"
        case .rejected(let m), .network(let m): return m
        }
    }
}

/// Looks books up on public catalogues. Open Library needs no key. Google Books answers
/// keyless requests with a zero quota nowadays, so it uses the user's own free API key.
/// Amazon has no public catalogue API (its Product Advertising API needs an affiliate account),
/// so the app only opens the Amazon search page for the user to read.
actor ResultBox {
    private var records: [MetadataCandidate] = []
    private var notes: [LookupError] = []
    func add(_ more: [MetadataCandidate]) { records += more }
    func note(_ error: LookupError) { notes.append(error) }
    func snapshot() -> ([MetadataCandidate], [LookupError]) { (records, notes) }
}

enum MetadataLookup {
    /// Calibre's order of work: by ISBN when the book has one (an exact edition), else by title
    /// and author, on every catalogue at once; the records are scored against the book and merged.
    static func identify(isbn: String?, title: String, author: String, googleKey: String?) async -> (records: [MetadataCandidate], notes: [LookupError]) {
        let box = ResultBox()
        let sources: [MetadataSource] = (googleKey?.isEmpty == false) ? [.openLibrary, .googleBooks] : [.openLibrary]
        if googleKey?.isEmpty != false { await box.note(.needsKey) }

        func run(isbn: String?) async {
            await withTaskGroup(of: (MetadataSource, Result<[MetadataCandidate], Error>).self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            let found = isbn != nil ? try await searchISBN(source, isbn: isbn!, googleKey: googleKey)
                                                    : try await search(source, title: title, author: author, googleKey: googleKey)
                            return (source, .success(found))
                        } catch { return (source, .failure(error)) }
                    }
                }
                for await (_, result) in group {
                    switch result {
                    case .success(let found): await box.add(found.map { var c = $0; c.matchedByISBN = isbn != nil; return c })
                    case .failure(let error): await box.note((error as? LookupError) ?? .network(error.localizedDescription))
                    }
                }
            }
        }
        // Both passes run at once: Open Library's ISBN endpoint is sometimes slow, and waiting for it
        // before starting the title search made a slow answer look like "no ISBN match".
        if let isbn {
            async let byISBN: Void = run(isbn: isbn)
            async let byTitle: Void = run(isbn: nil)
            _ = await (byISBN, byTitle)
        } else {
            await run(isbn: nil)
        }
        var (gathered, notes) = await box.snapshot()
        if isbn != nil, !gathered.contains(where: { $0.matchedByISBN }) { notes.append(.isbnMissed) }
        gathered = dedupe(gathered)
        return (rank(gathered, title: title, author: author), notes)
    }

    /// The same edition can come back from both passes: keep the ISBN-matched copy.
    static func dedupe(_ records: [MetadataCandidate]) -> [MetadataCandidate] {
        var seen: [String: Int] = [:]
        var out: [MetadataCandidate] = []
        for r in records {
            let key = [r.title.lowercased(), r.publisher.lowercased(), String(r.date.suffix(4))].joined(separator: "|")
            if let at = seen[key] {
                if r.matchedByISBN && !out[at].matchedByISBN { out[at] = r }
            } else { seen[key] = out.count; out.append(r) }
        }
        return out
    }

    static func searchISBN(_ source: MetadataSource, isbn: String, googleKey: String?) async throws -> [MetadataCandidate] {
        switch source {
        case .openLibrary:
            var parts = URLComponents(string: "https://openlibrary.org/api/books")!
            parts.queryItems = [URLQueryItem(name: "bibkeys", value: "ISBN:\(isbn)"), URLQueryItem(name: "format", value: "json"),
                                URLQueryItem(name: "jscmd", value: "data")]
            return parseOpenLibraryISBN(try await fetch(parts.url!), isbn: isbn)
        case .googleBooks:
            guard let key = googleKey, !key.isEmpty else { throw LookupError.needsKey }
            var parts = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
            parts.queryItems = [URLQueryItem(name: "q", value: "isbn:\(isbn)"), URLQueryItem(name: "key", value: key)]
            let data = try await fetch(parts.url!)
            if let error = parseGoogleError(data) { throw LookupError.rejected(error) }
            return parseGoogle(data)
        }
    }

    static func parseOpenLibraryISBN(_ data: Data, isbn: String) -> [MetadataCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json.values.compactMap { value in
            guard let v = value as? [String: Any], let title = v["title"] as? String else { return nil }
            var c = MetadataCandidate(source: .openLibrary, title: title)
            c.authors = (v["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            c.publisher = ((v["publishers"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            c.date = v["publish_date"] as? String ?? ""
            c.subjects = Array(((v["subjects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []).filter { $0.count < 40 }.prefix(3))
            c.isbn = isbn
            if let cover = v["cover"] as? [String: Any], let url = (cover["large"] ?? cover["medium"]) as? String { c.coverURL = URL(string: url + (url.contains("?") ? "" : "?default=false")) }
            c.pageURL = (v["url"] as? String).flatMap(URL.init(string:))
            return c
        }
    }

    /// Catalogue dates come in many shapes ("November 7, 2007", "2007-11", "2007"); the EPUB wants ISO.
    static func isoDate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for (format, output) in [("MMMM d, yyyy", "yyyy-MM-dd"), ("MMM d, yyyy", "yyyy-MM-dd"), ("d MMMM yyyy", "yyyy-MM-dd"),
                                 ("yyyy-MM-dd", "yyyy-MM-dd"), ("yyyy-MM", "yyyy-MM"), ("yyyy", "yyyy")] {
            f.dateFormat = format
            if let date = f.date(from: trimmed) {
                f.dateFormat = output
                return f.string(from: date)
            }
        }
        return trimmed
    }

    // MARK: Scoring and merging

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !["the", "of", "and", "an"].contains($0) })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// 0...1: how well a record matches the book (ISBN match counts most, then title, then author).
    static func score(_ c: MetadataCandidate, title: String, author: String) -> Double {
        let t = overlap(tokens(c.title), tokens(title))
        let a = author.isEmpty ? 0.5 : overlap(tokens(c.authors.joined(separator: " ")), tokens(author))
        var value = 0.6 * t + 0.25 * a + (c.matchedByISBN ? 0.15 : 0)
        let marks = ["adaptation", "abridged", "study guide", "summary", "analysis", "notes"]
        if marks.contains(where: { c.title.lowercased().contains($0) }) { value -= 0.2 }
        return max(0, min(1, value))
    }

    /// Sort by score, drop weak records, and put a combined record first when two or more agree.
    static func rank(_ records: [MetadataCandidate], title: String, author: String) -> [MetadataCandidate] {
        var scored = records.map { r -> MetadataCandidate in var c = r; c.sources = [r.source]; c.score = score(r, title: title, author: author); return c }
        scored.sort { $0.score > $1.score }
        scored = scored.filter { $0.score >= 0.35 }
        guard scored.count >= 2, let merged = merge(Array(scored.prefix(4))) else { return scored }
        return [merged] + scored
    }

    /// One record built field by field from the best-scoring records (the first non-empty value wins).
    /// Descriptions and covers prefer Google Books, which has them more often.
    static func merge(_ records: [MetadataCandidate]) -> MetadataCandidate? {
        guard let best = records.first, Set(records.map(\.source)).count > 1 else { return nil }
        var out = best
        out.id = UUID()
        out.combined = true
        out.sources = Array(Set(records.flatMap(\.sources))).sorted { $0.rawValue < $1.rawValue }
        func first<T>(_ path: (MetadataCandidate) -> T, empty: (T) -> Bool, prefer: MetadataSource? = nil) -> T {
            let ordered = prefer.map { p in records.sorted { ($0.source == p ? 0 : 1) < ($1.source == p ? 0 : 1) } } ?? records
            return ordered.map(path).first { !empty($0) } ?? path(best)
        }
        out.authors = first({ $0.authors }, empty: { $0.isEmpty })
        out.publisher = first({ $0.publisher }, empty: { $0.isEmpty })
        out.date = first({ $0.date }, empty: { $0.isEmpty })
        out.subjects = first({ $0.subjects }, empty: { $0.isEmpty })
        out.isbn = first({ $0.isbn }, empty: { $0.isEmpty })
        out.description = first({ $0.description }, empty: { $0.isEmpty }, prefer: .googleBooks)
        out.coverURL = first({ $0.coverURL }, empty: { $0 == nil }, prefer: .googleBooks)
        return out
    }

    static func search(_ source: MetadataSource, title: String, author: String, googleKey: String?) async throws -> [MetadataCandidate] {
        switch source {
        case .openLibrary: return try await openLibrary(title: title, author: author)
        case .googleBooks: return try await googleBooks(title: title, author: author, key: googleKey)
        }
    }

    static func amazonSearchURL(title: String, author: String) -> URL {
        var parts = URLComponents(string: "https://www.amazon.com/s")!
        parts.queryItems = [URLQueryItem(name: "k", value: "\(title) \(author)".trimmingCharacters(in: .whitespaces)),
                            URLQueryItem(name: "i", value: "stripbooks")]
        return parts.url!
    }

    // MARK: Open Library

    static func openLibrary(title: String, author: String) async throws -> [MetadataCandidate] {
        var parts = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "limit", value: "8"),
                     URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,publisher,subject,isbn,cover_i")]
        if !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        parts.queryItems = items
        return parseOpenLibrary(try await fetch(parts.url!))
    }

    static func parseOpenLibrary(_ data: Data) -> [MetadataCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { doc in
            guard let title = doc["title"] as? String else { return nil }
            var c = MetadataCandidate(source: .openLibrary, title: title)
            c.authors = doc["author_name"] as? [String] ?? []
            c.publisher = (doc["publisher"] as? [String])?.first ?? ""
            if let year = doc["first_publish_year"] as? Int { c.date = String(year) }
            c.subjects = Array(((doc["subject"] as? [String]) ?? []).filter { $0.count < 40 }.prefix(3))
            let isbns = ((doc["isbn"] as? [String]) ?? [])
            let thirteen = isbns.filter { $0.count == 13 }
            c.isbn = thirteen.first ?? isbns.first ?? ""
            c.altISBNs = Array(thirteen.dropFirst().prefix(2))
            if let cover = doc["cover_i"] as? Int { c.coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(cover)-L.jpg?default=false") }
            if let key = doc["key"] as? String { c.pageURL = URL(string: "https://openlibrary.org\(key)") }
            return c
        }
    }

    // MARK: Google Books

    static func googleBooks(title: String, author: String, key: String?) async throws -> [MetadataCandidate] {
        guard let key, !key.isEmpty else { throw LookupError.needsKey }
        var q = "intitle:\"\(title)\""
        if !author.isEmpty { q += "+inauthor:\"\(author)\"" }
        var parts = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        parts.percentEncodedQuery = "q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%20").replacingOccurrences(of: "%2B", with: "+") ?? q)
            + "&maxResults=8&printType=books&key=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)
        let data = try await fetch(parts.url!)
        if let error = parseGoogleError(data) { throw LookupError.rejected(error) }
        return parseGoogle(data)
    }

    static func parseGoogleError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "error"
    }

    static func parseGoogle(_ data: Data) -> [MetadataCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let info = item["volumeInfo"] as? [String: Any], let title = info["title"] as? String else { return nil }
            var c = MetadataCandidate(source: .googleBooks, title: title)
            c.authors = info["authors"] as? [String] ?? []
            c.publisher = info["publisher"] as? String ?? ""
            c.date = info["publishedDate"] as? String ?? ""
            c.description = info["description"] as? String ?? ""
            c.subjects = Array(((info["categories"] as? [String]) ?? []).prefix(5))
            let ids = info["industryIdentifiers"] as? [[String: Any]] ?? []
            c.isbn = (ids.first { ($0["type"] as? String) == "ISBN_13" }?["identifier"] as? String) ?? (ids.first?["identifier"] as? String) ?? ""
            if let links = info["imageLinks"] as? [String: Any],
               let thumb = (links["large"] ?? links["medium"] ?? links["thumbnail"] ?? links["smallThumbnail"]) as? String {
                c.coverURL = URL(string: thumb.replacingOccurrences(of: "http://", with: "https://"))
            }
            c.pageURL = (info["infoLink"] as? String).flatMap(URL.init(string:))
            return c
        }
    }

    // MARK: Network

    private static func fetch(_ url: URL) async throws -> Data {
        var lastError = LookupError.network("no answer")
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: 45)    // the public catalogues can take 10 s or more
            request.setValue("BookTranslator/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 500 { throw LookupError.network("HTTP \(http.statusCode)") }
                return data
            } catch let error as LookupError { lastError = error }
            catch let error as URLError where error.code == .timedOut { throw LookupError.network(error.localizedDescription) }
            catch { lastError = .network(error.localizedDescription) }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
        throw lastError
    }

    /// Download a cover to a temp file the engine can read; nil when none of the sources has one.
    static func downloadCover(for candidate: MetadataCandidate) async -> URL? {
        guard let data = await CoverFetcher.fetch(CoverFetcher.sources(for: candidate)) else { return nil }
        let isPNG = data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bt-cover-\(UUID().uuidString).\(isPNG ? "png" : "jpg")")
        return (try? data.write(to: file)) == nil ? nil : file
    }
}

/// Finds a cover for a catalogue record. Open Library's cover-by-id links go through archive.org and
/// often time out, so covers are looked up by ISBN first (fast on Open Library and on Google's keyless
/// cover endpoint); the by-id link is the last resort.
enum CoverFetcher {
    static func sources(for c: MetadataCandidate) -> [URL] {
        var urls: [URL] = []
        for isbn in ([c.isbn] + c.altISBNs).filter({ !$0.isEmpty }).prefix(3) {
            urls.append(URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-M.jpg?default=false")!)
            urls.append(URL(string: "https://books.google.com/books/content?vid=ISBN:\(isbn)&printsec=frontcover&img=1&zoom=1")!)
        }
        if let url = c.coverURL, !urls.contains(url) { urls.append(url) }
        return urls
    }

    /// Image bytes (JPEG, PNG or GIF, not a placeholder) from the first source that answers in time.
    static func fetch(_ urls: [URL], timeout: TimeInterval = 7) async -> Data? {
        for url in urls.prefix(5) {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("BookTranslator/1.0", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, isRealImage(data) else { continue }
            return data
        }
        return nil
    }

    /// A known image format and big enough not to be a "no cover" placeholder.
    static func isRealImage(_ data: Data) -> Bool {
        guard data.count > 2_000 else { return false }
        return data.prefix(2) == Data([0xFF, 0xD8]) || data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) || data.prefix(3) == Data([0x47, 0x49, 0x46])
    }
}

/// The user's own Google Books API key, kept in the Keychain (never in the repo or defaults).
enum Secrets {
    private static let service = "com.aansun.BookTranslator"
    private static let account = "googleBooksAPIKey"

    static var googleBooksKey: String {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
