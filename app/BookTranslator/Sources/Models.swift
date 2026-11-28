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
    var models: [String: String]? = nil   // tier -> the app's recommended model, when active
    var id: String { name }

    /// Every engine the translator knows, in its default order.
    static let known = ["claude", "codex", "agy", "opencode"]

    /// The model that translates novels, as shown in Settings ("name@high" reads "name (high)").
    var modelName: String? {
        guard let model = models?["sonnet"], !model.isEmpty else { return nil }
        return Self.display(model)
    }

    /// "name@high" (a model and its reasoning effort) reads "name (high)".
    static func display(_ model: String) -> String {
        let parts = model.split(separator: "@")
        return parts.count == 2 ? "\(parts[0]) (\(parts[1]))" : model
    }

    var lacksRecommendedModel: Bool { !active && reason.hasPrefix("no recommended model") }

    /// The saved order, with the engines it does not name yet at the end: a saved order must
    /// not hide an engine a newer version added. Empty stays empty (the engine's default).
    static func completeOrder(_ saved: [String]) -> [String] {
        saved.isEmpty ? [] : saved + known.filter { !saved.contains($0) }
    }
}

/// One engine of `translate_book.py --list-models`: the app's recommendation and what else it offers.
struct ModelChoices: Codable, Equatable {
    var recommended: String
    var choices: [String]
}

extension Array where Element == EngineInfo {
    /// The engines in a new order, each with its new role: the first active one is the main one.
    func arranged(_ names: [String]) -> [EngineInfo] {
        var taken = false
        return names.compactMap { name in first { $0.name == name } }.map { engine in
            var engine = engine
            engine.role = engine.active ? (taken ? "backup" : "main") : ""
            taken = taken || engine.active
            return engine
        }
    }
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
    var warnings: [String]? = nil   // signs of a poor source file: "garbled", "scanned", "broken_paragraphs"
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

/// Who picks a book's writing style.
enum StyleMode: String, CaseIterable {
    case auto      // the recommended style is used and the translation starts right away
    case manual    // the user confirms the style (and the names) before the translation
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
    var reviewChoice: Bool?       // this book's own choice to confirm the style first (nil = the setting)
    var style = "auto"
    var targetLanguage: String?   // fixed when the book joins the queue (nil = Indonesian)
    var workdir: String?          // folder name under books/ once the engine has taken the book
    var volume = 0
    var pct = 0
    var polishing = false         // the percentage belongs to the polish pass, not the translation
    var step = ""                 // the stage last worked on: "prepare", "translate", "refine" or "check"
    var times: [String: Int] = [:]   // seconds spent per stage (of the current volume), kept across restarts
    var polishPlanned: Bool?      // whether the engine's last run polishes this book
    var polishOnly = false        // already translated: polished and checked, not translated
    var retryAt: Date?            // waiting for a usage limit to pass: when to try again
    var waitingFor = ""           // the engine waited for; kept until the book is done, to tell it once
    var needsPrepare = false      // the limit came before the preparation was finished
    var warnings: [String] = []   // what the first look found wrong with the source file
    var error = ""

    /// Only a single EPUB can be polished on its own.
    var canPolishOnly: Bool { fileName.lowercased().hasSuffix(".epub") }
    /// A polish-only book is never split.
    var shownVolumes: Int { polishOnly ? 1 : volumes }
    /// The inspected estimate covers translating and, for a novel, polishing: about half each.
    var expectedMinutes: Int {
        polishOnly && kind == .fiction && estimatedMinutes > 0 ? max(1, estimatedMinutes / 2) : estimatedMinutes
    }

    /// Which wording fits these books: "" to translate, ".polish" only to polish, ".mixed" both.
    static func wordingSuffix(_ books: [QueueBook]) -> String {
        let polished = books.filter(\.polishOnly).count
        return polished == 0 ? "" : (polished == books.count ? ".polish" : ".mixed")
    }

    /// Is a book in `source` already written in `target`? ("Bahasa Indonesia" counts as "Indonesian".)
    static func isWritten(_ source: String, in target: String) -> Bool {
        func plain(_ name: String) -> String {
            let name = name.trimmingCharacters(in: .whitespaces).lowercased()
            return ["bahasa indonesia", "id"].contains(name) ? "indonesian" : name
        }
        return !source.isEmpty && plain(source) == plain(target)
    }

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
        reviewChoice = try saved.decodeIfPresent(Bool.self, forKey: .reviewChoice)
        style = try read(.style, or: style)
        targetLanguage = try saved.decodeIfPresent(String.self, forKey: .targetLanguage)
        workdir = try saved.decodeIfPresent(String.self, forKey: .workdir)
        volume = try read(.volume, or: volume)
        pct = try read(.pct, or: pct)
        polishing = try read(.polishing, or: polishing)
        step = try read(.step, or: step)
        times = try read(.times, or: times)
        polishPlanned = try saved.decodeIfPresent(Bool.self, forKey: .polishPlanned)
        polishOnly = try read(.polishOnly, or: polishOnly)
        retryAt = try saved.decodeIfPresent(Date.self, forKey: .retryAt)
        waitingFor = try read(.waitingFor, or: waitingFor)
        needsPrepare = try read(.needsPrepare, or: needsPrepare)
        warnings = try read(.warnings, or: warnings)
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
    var stage: String?            // "prepare", "translate" or "refine" while running
    var times: [String: Int]?     // seconds per stage so far
    var polish: Bool?
}

/// One step of the way a book goes, as shown above its title.
struct BookStage: Identifiable, Equatable {
    enum State: Equatable { case done, active, pending, skipped }
    var id: String                // "prepare", "translate", "refine", "check"
    var state: State
    var seconds: Int
    var polishOnly = false        // the book is only polished: its preparation has no glossary

    var titleKey: String { polishOnly && id == "prepare" ? "stage.prepare.polish" : "stage.\(id)" }

    static let order = ["prepare", "translate", "refine", "check"]

    /// Where `book` stands. `polishByDefault` answers for a run that has not said yet.
    static func steps(for book: QueueBook, polishByDefault: Bool) -> [BookStage] {
        var current = book.step
        if book.stage == .preparing { current = "prepare" }
        else if current.isEmpty {
            current = book.polishing ? "refine" : (book.pct > 0 ? (book.polishOnly ? "refine" : "translate") : "prepare")
        }
        // prepared but not translating yet: the preparation is behind us, nothing is active
        let waiting = book.stage == .needsReview
            || (book.stage != .translating && book.stage != .preparing && current == "prepare" && book.workdir != nil)
        if waiting { current = book.polishOnly ? "refine" : "translate" }
        let at = order.firstIndex(of: current) ?? 0
        let polishes = book.polishOnly || current == "refine" || (book.polishPlanned ?? polishByDefault)
        return order.enumerated().map { index, id in
            var state: State = index < at ? .done : (index == at ? (waiting ? .pending : .active) : .pending)
            if id == "refine" && !polishes { state = .skipped }
            if id == "translate" && book.polishOnly { state = .skipped }
            return BookStage(id: id, state: state, seconds: book.times[id] ?? 0, polishOnly: book.polishOnly)
        }
    }
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
    var mode: String?              // "polish" for a book that was only polished
    var volumes: [VolumeInfo]
    var folder: String = ""        // set by the loader: the folder name under books/
    var authorName: String = ""    // set by the loader from the first EPUB
    var series: String = ""        // set by the loader from the first EPUB
    var check: CheckReport?        // set by the loader from check.json
    var kindleMark = KindleMark.none   // set by the loader from kindle.json

    var id: String { folder }
    var isPolishOnly: Bool { mode == "polish" }
    var kind: BookKind { (isFiction ?? false) ? .fiction : .nonfiction }
    var isComplete: Bool { !volumes.isEmpty && volumes.allSatisfy { $0.status == "completed" } }
    var qaFlagCount: Int { volumes.reduce(0) { $0 + ($1.qaFlags ?? 0) } }
    var missingCount: Int { volumes.reduce(0) { $0 + ($1.metadataMissing?.count ?? 0) } }
    var updatedDate: Date? { ISO8601DateFormatter().date(from: updatedAt ?? "") }

    enum CodingKeys: String, CodingKey {
        case title, titleTranslated, sourceLanguage, targetLanguage, genre, isFiction, updatedAt, qaReport, mode, volumes
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
