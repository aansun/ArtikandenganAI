import SwiftUI

/// books/<book>/check.json: what the engine's last stage found in each finished volume.
struct CheckReport: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String            // "pages", "length", "links"...
        var level: String         // "ok", "info", "warn", "fail"
        var count: Int
        var items: [String]
    }
    struct Volume: Codable, Equatable {
        var index: Int
        var overall: String
        var checks: [Item]
    }
    var overall: String
    var volumes: [Volume]

    var needsLook: Bool { overall == "warn" || overall == "fail" }
    /// A finding that can be mended without translating again.
    var canRepair: Bool {
        volumes.flatMap(\.checks).contains { ["splits", "toc"].contains($0.id) && $0.level != "ok" }
    }
    /// How many checks ask for a look.
    var problems: Int { volumes.flatMap(\.checks).filter { $0.level == "warn" || $0.level == "fail" }.count }

    static func read(_ folder: URL) -> CheckReport? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("check.json")) else { return nil }
        return try? JSONDecoder().decode(CheckReport.self, from: data)
    }
}

/// The book that finished last, shown on Progress with all its stages and the check's verdict.
struct FinishedBook: Equatable {
    var folder: String
    var book: QueueBook
    var report: CheckReport?
}

enum CheckStyle {
    static func symbol(_ level: String) -> String {
        switch level {
        case "fail": return "xmark.octagon.fill"
        case "warn": return "exclamationmark.triangle.fill"
        case "info": return "info.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }
    static func color(_ level: String) -> Color {
        switch level {
        case "fail": return Theme.danger
        case "warn": return Theme.warnIcon
        case "info": return Theme.faint
        default: return Theme.green
        }
    }
    /// The line of one check. A polished book is compared with the translation it came from, not an original.
    static func key(_ item: CheckReport.Item, polishOnly: Bool) -> String {
        let state = item.level == "ok" ? "ok" : "found"
        let own = "check.polished.\(item.id).\(state)"
        return polishOnly && Loc.table[own] != nil ? own : "check.\(item.id).\(state)"
    }
    static func verdict(_ report: CheckReport?, _ loc: Loc) -> String {
        guard let report else { return loc.t("check.none") }
        switch report.overall {
        case "fail": return loc.t("check.verdict.fail", report.problems)
        case "warn": return loc.t("check.verdict.warn", report.problems)
        default: return loc.t("check.verdict.ok")
        }
    }
}

/// The result of the check, one line per thing looked at, with what was found under it.
struct CheckCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    @State private var failure = ""

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: CheckStyle.symbol(book.check?.overall ?? "info"))
                        .foregroundStyle(CheckStyle.color(book.check?.overall ?? "info"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc.t("check.title")).font(.system(size: 13, weight: .semibold))
                        Text(CheckStyle.verdict(book.check, loc)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(book.check?.volumes ?? [], id: \.index) { volume in
                    if (book.check?.volumes.count ?? 0) > 1 {
                        Text(loc.t("detail.volumeN", volume.index)).font(.system(size: 12, weight: .semibold)).padding(.top, 2)
                    }
                    ForEach(volume.checks) { line($0) }
                }
                if book.check != nil { Text(loc.t(book.isPolishOnly ? "check.limitPolish" : "check.limit")).font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
                if !failure.isEmpty { Text(failure).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(3) }
                HStack(spacing: 6) {
                    if book.check?.canRepair == true && !book.isPolishOnly {
                        Button(loc.t("check.repair")) {
                            Task { failure = await model.repair(book.folder) ?? "" }
                        }.buttonStyle(PrimaryButtonStyle(radius: 8, vertical: 5, horizontal: 12, size: 12.5))
                            .disabled(model.checking != nil || !model.env.isReady || !model.canDelete(book.folder))
                            .help(loc.t("check.repairHelp"))
                    }
                    Button(model.checking == book.folder ? loc.t("check.running") : loc.t(book.check == nil ? "check.run" : "check.again")) {
                        Task { failure = await model.recheck(book.folder) ?? "" }
                    }.buttonStyle(GhostButtonStyle()).disabled(model.checking != nil || !model.env.isReady)
                    if let report = book.qaReport, !report.isEmpty, FileManager.default.fileExists(atPath: report) {
                        Button(loc.t("detail.qaOpen")) { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ item: CheckReport.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: CheckStyle.symbol(item.level)).font(.system(size: 10)).foregroundStyle(CheckStyle.color(item.level))
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t(CheckStyle.key(item, polishOnly: book.isPolishOnly))).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if item.level != "ok" {
                    ForEach(Array(item.items.prefix(4).enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
                    }
                    if item.count > 4 { Text(loc.t("check.more", item.count - 4)).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                }
            }
        }
    }
}
