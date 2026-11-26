import SwiftUI

/// What deleting a library book takes with it, read from its folder.
struct DeletionPlan: Identifiable, Equatable {
    var id: String { folder.path }
    var folder: URL
    var translations: [String] = []
    var hasSource = false
    var terms = 0
    var hasStyle = false
    var hasProgress = false
    var olderVersions = 0
    var series = ""               // set when other books of the library belong to it too
    var bytes: Int64 = 0

    init(folder: URL, others: [URL] = []) {
        self.folder = folder
        let fm = FileManager.default
        func names(_ sub: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        translations = names("translation").filter { ["epub", "txt"].contains(($0 as NSString).pathExtension.lowercased()) }
        olderVersions = names("previous").count
        hasSource = !names("source").isEmpty
        hasStyle = has("style.md") || has("style.json") || has("calibration.md")
        hasProgress = has("jobs.db") || has("state.json") || has("stages.json")
        terms = Self.object(folder.appendingPathComponent("glossary.json"))?["terms"].flatMap { ($0 as? [Any])?.count } ?? 0
        let mine = Self.seriesName(folder)
        if !mine.isEmpty, others.contains(where: { Self.seriesName($0).caseInsensitiveCompare(mine) == .orderedSame }) {
            series = mine
        }
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
    }

    private static func object(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func seriesName(_ folder: URL) -> String {
        object(folder.appendingPathComponent("book.json"))?["series"] as? String ?? ""
    }
}

/// The warning before a book leaves the library: what goes, what stays.
struct DeleteBookSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: LibraryBook
    var plan: DeletionPlan
    var close: (_ deleted: Bool) -> Void
    @State private var failure = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "trash.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.danger)
                Text(loc.t("delete.title", book.title)).font(.system(size: 17, weight: .semibold)).lineLimit(3)
            }
            Text(loc.t("delete.intro")).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 7) {
                if !plan.translations.isEmpty {
                    item(loc.t("delete.translations", plan.translations.count), plan.translations.joined(separator: "\n"))
                }
                if plan.hasSource { item(loc.t("delete.source")) }
                if plan.terms > 0 { item(loc.t("delete.glossary", plan.terms)) }
                if plan.hasStyle { item(loc.t("delete.style")) }
                if plan.hasProgress { item(loc.t("delete.progress")) }
                if plan.olderVersions > 0 { item(loc.t("delete.previous", plan.olderVersions)) }
                item(loc.t("delete.metadata"))
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.dangerBg, in: RoundedRectangle(cornerRadius: 10))
            if !plan.series.isEmpty { note(loc.t("delete.series", plan.series), Theme.warnText) }
            note(loc.t("delete.kept"), Theme.muted)
            note(loc.t("delete.trash", ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)), Theme.muted)
            if !failure.isEmpty { note(loc.t("delete.failed", failure), Theme.danger) }
            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { close(false) }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Button(loc.t("delete.confirm")) {
                    if let why = model.deleteBook(book.folder) { failure = why } else { close(true) }
                }.buttonStyle(PrimaryButtonStyle(radius: 8, fill: Theme.danger))
            }
            .padding(.top, 4)
        }
        .padding(22).frame(width: 480)
        .background(Theme.card)
    }

    private func item(_ title: String, _ detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "minus.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(6).truncationMode(.middle)
                }
            }
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
