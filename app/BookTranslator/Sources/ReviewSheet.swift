import SwiftUI

/// Fiction: check the locked names and choose the writing style once, before the long run.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook
    @State private var choice: String = ""
    @State private var style: StyleChoice?
    @State private var terms: [GlossaryTerm] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc.t("review.title", book.title)).font(.title2.weight(.semibold))
            Text(loc.t("review.intro")).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    namesSection
                    styleSection
                }
            }
            Divider()
            HStack {
                Text(loc.t("review.otherBooks")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("review.later")) { model.reviewTarget = nil }
                Button(loc.t("review.approve")) { model.approve(book.id, style: choice) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 640)
        .onAppear {
            style = model.styleChoice(for: book)
            terms = model.glossaryTerms(for: book)
            choice = style?.recommended ?? "auto"
        }
    }

    private var shownTerms: [GlossaryTerm] {
        let rank = ["character": 0, "place": 1, "organization": 2]
        return terms.sorted { (rank[$0.category ?? ""] ?? 9) < (rank[$1.category ?? ""] ?? 9) }.prefix(10).map { $0 }
    }

    private var namesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("review.names", terms.count, shownTerms.count)).font(.headline)
            Text(loc.t("review.namesHint")).font(.caption).foregroundStyle(.secondary)
            ForEach(shownTerms) { term in
                HStack {
                    Text(term.source).font(.body.weight(.medium))
                    Text("· \(term.category ?? "")").foregroundStyle(.secondary)
                    Spacer()
                    Text(term.decision == "keep" ? loc.t("review.keep") : "→ \(term.target)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            if let url = model.file("glossary.json", of: book) {
                Button(loc.t("review.editGlossary")) { NSWorkspace.shared.open(url) }.buttonStyle(.link)
            }
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("review.style")).font(.headline)
            if let why = style?.why, !why.isEmpty { Text(why).font(.callout).foregroundStyle(.secondary) }
            ForEach(style?.options ?? []) { option in
                Button { choice = option.id } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: choice == option.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(loc.styleName(option.id)).font(.body.weight(.medium))
                                if option.id == style?.recommended { Chip(text: loc.t("review.recommended"), tint: Theme.accent) }
                            }
                            Text(loc.styleText(option.id)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(choice == option.id ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(choice == option.id ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
            }
            if let url = model.file("calibration.md", of: book), FileManager.default.fileExists(atPath: url.path) {
                Button(loc.t("review.calibration")) { NSWorkspace.shared.open(url) }.buttonStyle(.link)
            }
        }
    }
}
