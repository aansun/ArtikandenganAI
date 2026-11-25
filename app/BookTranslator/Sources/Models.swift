import Foundation

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
    var workdir: String?          // folder name under books/ once the engine has taken the book
    var volume = 0
    var pct = 0
    var error = ""

    var isQueued: Bool { [.queued, .preparing, .needsReview, .approved, .translating, .failed].contains(stage) }
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
