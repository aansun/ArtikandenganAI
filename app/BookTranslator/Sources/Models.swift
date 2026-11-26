import Foundation

/// Languages offered as the translation target (English names, as the engine expects).
enum TargetLanguages {
    static let all = ["Indonesian", "English", "Malay", "Spanish", "French", "German", "Italian", "Portuguese (Brazil)", "Dutch",
                      "Russian", "Arabic", "Hindi", "Japanese", "Korean", "Chinese", "Thai", "Vietnamese", "Turkish"]
}

enum BookKind: String, Codable {
    case fiction = "fiksi"
    case nonfiction = "nonfiksi"

    var key: String { self == .fiction ? "kind.fiction" : "kind.nonfiction" }
    var other: BookKind { self == .fiction ? .nonfiction : .fiction }
}

/// An engine reported by `translate_book.py --detect`.
struct EngineInfo: Codable, Identifiable, Equatable {
    var name: String
    var label: String
    var active: Bool
    var reason: String
    var role: String
    var id: String { name }
}

/// Output of `translate_book.py --inspect FILE`.
struct InspectResult: Codable, Equatable {
    var file: String
    var title: String
    var author: String
    var volumes: Int
    var sourceLanguage: String
    var kind: BookKind
    var estimatedMinutes: Int
    var words: Int
}

enum Stage: String, Codable {
    case reading      // being inspected
    case uploaded     // in the left card
    case ready        // in the right card of Add, not started yet
    case queued       // started: waiting in the Progress queue
    case preparing    // glossary, style and sample being made
    case needsReview  // waiting for the user's approval
    case approved     // reviewed, waiting to be translated
    case translating
    case failed
}

/// One book in the Add / Progress screens.
struct QueueBook: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String          // file or folder inside books/inbox
    var title: String
    var author: String = ""
    var volumes: Int = 1
    var kind: BookKind = .fiction
    var estimatedMinutes: Int = 0
    var stage: Stage = .reading
    var reviewFirst = true
    var style = "auto"
    var targetLanguage: String?   // fixed when the book joins the queue (nil = Indonesian)
    var workdir: String?          // folder name under books/ once the engine has taken the book
    var volume = 0
    var pct = 0
    var polishing = false         // the percentage belongs to the polish pass, not the translation
    var error = ""

    var isQueued: Bool { [.queued, .preparing, .needsReview, .approved, .translating, .failed].contains(stage) }
}

extension QueueBook {
    /// The queue file outlives app versions: a field it does not have yet takes its default.
    /// (The synthesized decoder demands every non-optional field, so one added field lost the whole queue.)
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fileName: try saved.decode(String.self, forKey: .fileName),
                  title: try saved.decode(String.self, forKey: .title))
        func read<T: Decodable>(_ key: CodingKeys, or fallback: T) throws -> T {
            try saved.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        id = try read(.id, or: id)
        author = try read(.author, or: author)
        volumes = try read(.volumes, or: volumes)
        kind = try read(.kind, or: kind)
        estimatedMinutes = try read(.estimatedMinutes, or: estimatedMinutes)
        stage = try read(.stage, or: .uploaded)
        reviewFirst = try read(.reviewFirst, or: reviewFirst)
        style = try read(.style, or: style)
        targetLanguage = try saved.decodeIfPresent(String.self, forKey: .targetLanguage)
        workdir = try saved.decodeIfPresent(String.self, forKey: .workdir)
        volume = try read(.volume, or: volume)
        pct = try read(.pct, or: pct)
        polishing = try read(.polishing, or: polishing)
        error = try read(.error, or: error)
    }
}

/// What the engine reports in books/status.json while it works.
struct EngineStatus: Codable, Equatable {
    var state: String
    var book: String
    var title: String
    var volume: Int
    var volumes: Int
    var pct: Int
    var engine: String
    /// "translate" or "refine": the polish pass counts its own chunks again from 0.
    var phase: String?
}

struct StyleOption: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
}

/// books/<book>/style.json
struct StyleChoice: Codable, Equatable {
    var options: [StyleOption]
    var recommended: String
    var why: String
    var chosen: String
}

struct GlossaryTerm: Codable, Identifiable, Equatable {
    var source: String
    var target: String
    var decision: String
    var category: String?
    var id: String { source }
}

struct Glossary: Codable {
    var terms: [GlossaryTerm]
}

struct VolumeInfo: Codable, Identifiable, Equatable {
    var index: Int
    var label: String
    var output: String
    var status: String
    var title: String?
    var finishedAt: String?
    var metadataMissing: [String]?
    var qaFlags: Int?
    var id: Int { index }
}

/// books/<book>/book.json
struct LibraryBook: Codable, Identifiable, Equatable {
    var title: String
    var titleTranslated: String?
    var sourceLanguage: String?
    var targetLanguage: String?
    var genre: String?
    var isFiction: Bool?
    var updatedAt: String?
    var qaReport: String?
    var volumes: [VolumeInfo]
    var folder: String = ""        // set by the loader: the folder name under books/
    var authorName: String = ""    // set by the loader from the first EPUB
    var series: String = ""        // set by the loader from the first EPUB

    var id: String { folder }
    var kind: BookKind { (isFiction ?? false) ? .fiction : .nonfiction }
    var isComplete: Bool { !volumes.isEmpty && volumes.allSatisfy { $0.status == "completed" } }
    var qaFlagCount: Int { volumes.reduce(0) { $0 + ($1.qaFlags ?? 0) } }
    var missingCount: Int { volumes.reduce(0) { $0 + ($1.metadataMissing?.count ?? 0) } }
    var updatedDate: Date? { ISO8601DateFormatter().date(from: updatedAt ?? "") }

    enum CodingKeys: String, CodingKey {
        case title, titleTranslated, sourceLanguage, targetLanguage, genre, isFiction, updatedAt, qaReport, volumes
    }
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
