import SwiftUI

/// "Check first" sheet for fiction, as in the design: names on the left, style and a sample on the right.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook
    @State private var choice = "auto"
    @State private var style: StyleChoice?
    @State private var terms: [GlossaryTerm] = []
    @State private var decisions: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                Group { if book.polishOnly { polishColumn } else { namesColumn } }.frame(width: 380)
                Rectangle().fill(Theme.divider).frame(width: 1)
                styleColumn.frame(maxWidth: .infinity)
            }
            footer
        }
        .frame(width: 900, height: 600)
        .background(Theme.card)
        .onAppear {
            style = model.styleChoice(for: book)
            terms = model.glossaryTerms(for: book)
            decisions = Dictionary(uniqueKeysWithValues: terms.map { ($0.source, $0.decision) })
            choice = style?.recommended ?? "auto"
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverView(title: book.title, image: model.queueCovers[book.id], width: 40, height: 56, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("review.title", book.title)).font(.system(size: 18, weight: .semibold))
                Text(loc.t(book.polishOnly ? "review.introPolish"
                           : (book.kind == .fiction ? "review.intro" : "review.introNonfiction")))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    // MARK: - Polish only

    /// A polished book has no list of names: say what happens to it instead.
    private var polishColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("mode.polish")).font(.system(size: 13, weight: .semibold))
            ForEach(["review.polish.language", "review.polish.names", "review.polish.pronouns",
                     "review.polish.file", "review.polish.limit"], id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: key == "review.polish.limit" ? "info.circle" : "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(loc.t(key)).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Names

    private func category(_ term: GlossaryTerm) -> String {
        let key = "cat.\(term.category ?? "term")"
        return Loc.table[key] != nil ? loc.t(key) : (term.category ?? "").capitalized
    }

    private var namesColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(loc.t("review.names2", terms.count)).font(.system(size: 13, weight: .semibold)))
            Text(loc.t("review.namesHint")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(terms) { term in
                        let keep = (decisions[term.source] ?? term.decision) == "keep"
                        let canTranslate = term.target != term.source
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(term.source).font(.system(size: 13, weight: .medium))
                                Text("\(category(term)) · \(loc.t("review.written", keep ? term.source : term.target))")
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            HStack(spacing: 0) {
                                seg(loc.t("review.keep"), on: keep, enabled: true) { decisions[term.source] = "keep" }
                                seg(loc.t("review.translate"), on: !keep, enabled: canTranslate) {
                                    decisions[term.source] = term.decision == "keep" ? "translate" : term.decision
                                }
                            }
                            .padding(2).background(Theme.neutralBg, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.subtleDivider).frame(height: 1) }
                    }
                }
            }
            if let url = model.file("glossary.json", of: book) {
                Button(loc.t("review.editGlossary")) { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func seg(_ label: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(on ? Theme.selectedSeg : .clear, in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 1, y: 1)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    // MARK: - Style

    private var styleColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text(loc.t("review.style")).font(.system(size: 13, weight: .semibold))
                if let why = style?.why, !why.isEmpty { Text(why).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(style?.options ?? []) { option in
                    let on = choice == option.id
                    Button { choice = option.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().stroke(on ? Theme.accent : Theme.stageIdle, lineWidth: 2).frame(width: 16, height: 16)
                                if on { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
                            }.padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(loc.styleName(option.id)).font(.system(size: 13, weight: .semibold))
                                    if option.id == style?.recommended { Pill(text: loc.t("review.recommended"), bg: Theme.okBg, fg: Theme.okText) }
                                }
                                Text(loc.styleText(option.id)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(on ? Theme.selectedFill : Theme.card, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? Theme.accent : Theme.unselectedBorder, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
                if !book.polishOnly {       // the samples show a translation
                    Text(loc.t("review.sampleTitle")).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
                    Text(loc.t("sample.source")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(3)
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
                    Text(loc.t("sample.\(Loc.table["sample.\(choice)"] != nil ? choice : "formal")")).font(.system(size: 13)).lineSpacing(4)
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.selectedFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.readyLine))
                }
                if let url = model.file("calibration.md", of: book), FileManager.default.fileExists(atPath: url.path) {
                    Button(loc.t("review.calibration")) { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(loc.t("review.otherBooks")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button(loc.t("review.later")) { model.reviewTarget = nil }.buttonStyle(GhostButtonStyle()).controlSize(.large)
            Button(loc.t("review.approve")) {
                model.saveGlossary(for: book, decisions: decisions)
                model.approve(book.id, style: choice)
            }.buttonStyle(PrimaryButtonStyle(radius: 8)).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}
