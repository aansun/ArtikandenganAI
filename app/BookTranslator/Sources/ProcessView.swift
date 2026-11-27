import SwiftUI

/// Step 2, as in the design: the running book (cover, status, engine, volume dots, progress,
/// estimate, pause) and the waiting queue as one table.
struct ProcessView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var goInput: () -> Void
    var openResult: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let done = model.finished { finishedCard(done) }
            if let current = model.currentBook { runningCard(current) }
            else if model.paused, !model.queueList.isEmpty { pausedCard }
            else if !model.isBusy, model.waitingCount > 0 { stalledCard }
            if model.queueList.isEmpty { if model.finished == nil { empty } }
            else if !waiting.isEmpty { queueTable }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }

    private var waiting: [QueueBook] { model.queueList.filter { $0.id != model.currentBook?.id } }

    private var empty: some View {
        VStack(spacing: 12) {
            Text(loc.t("process.empty")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(loc.t("process.emptyHint")).foregroundStyle(Theme.muted)
            Button(loc.t("process.goInput"), action: goInput).buttonStyle(PrimaryButtonStyle(radius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.buttonLine, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
    }

    /// Books are queued but nothing runs (after a restart, or when an engine stopped): say so and offer the button.
    private var stalledCard: some View {
        CardBox(radius: 16) {
            HStack {
                Text(loc.t("process.stalled", model.waitingCount)).font(.system(size: 14, weight: .medium))
                Spacer()
                Button(loc.t("process.startQueue")) { model.start() }.buttonStyle(PrimaryButtonStyle(radius: 8))
            }.padding(22)
        }
    }

    private var pausedCard: some View {
        CardBox(radius: 16) {
            HStack {
                Text(loc.t("process.paused")).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.warnIcon)
                Spacer()
                Button(loc.t("process.resume")) { model.resume() }.buttonStyle(PrimaryButtonStyle(radius: 8))
            }.padding(22)
        }
    }

    // MARK: - Running card

    private func runningCard(_ book: QueueBook) -> some View {
        let preparing = book.stage == .preparing
        let live = model.running?.id == book.id          // false: stopped part way, waiting to go on
        let paused = model.paused || !live
        let tint = paused ? Theme.amber : Theme.accent
        return CardBox(radius: 16) {
            HStack(alignment: .top, spacing: 22) {
                CoverView(title: book.title, image: model.queueCovers[book.id], width: 100, height: 144, radius: 6)
                VStack(alignment: .leading, spacing: 9) {
                    StageSteps(steps: BookStage.steps(for: book, polishByDefault: model.polishNovels && book.kind == .fiction),
                               paused: paused)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(book.title).font(.system(size: 21, weight: .semibold))
                        Text("\(book.author.isEmpty ? "" : book.author + " · ")\(loc.volumes(book.volumes))")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    if live { engineLine }
                    if !preparing {
                        HStack(spacing: 5) {
                            ForEach(1...max(book.volumes, 1), id: \.self) { i in
                                RoundedRectangle(cornerRadius: 4).fill(dotColor(i, book: book, tint: tint)).frame(height: 8)
                            }
                        }
                        HStack {
                            Text(loc.t("process.volumeOf", max(book.volume, 1), book.volumes))
                            Spacer()
                            Text(loc.t("process.volThis", book.pct))
                        }.font(.system(size: 12)).foregroundStyle(Theme.muted)
                        ProgressBar(value: Double(book.pct) / 100, tint: tint)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    }
                    HStack(spacing: 8) {
                        Text(etaText(paused: paused)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Spacer()
                        if model.paused {
                            Button(loc.t("process.resume")) { model.resume() }.buttonStyle(PrimaryButtonStyle(radius: 8))
                        } else if live {
                            Button(loc.t("process.pause")) { model.pause() }.buttonStyle(GhostButtonStyle())
                        } else if !model.isBusy {
                            Button(loc.t("process.startQueue")) { model.start() }.buttonStyle(PrimaryButtonStyle(radius: 8))
                        }
                    }.padding(.top, 2)
                }
            }
            .padding(22)
        }
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    /// All four stages done, and what the last one found.
    private func finishedCard(_ done: FinishedBook) -> some View {
        var steps = BookStage.steps(for: done.book, polishByDefault: model.polishNovels && done.book.kind == .fiction)
        for index in steps.indices where steps[index].state != .skipped { steps[index].state = .done }
        let level = done.report?.overall ?? "info"
        return CardBox(radius: 16) {
            HStack(alignment: .top, spacing: 18) {
                CoverView(title: done.book.title, image: model.library.covers[done.folder] ?? model.queueCovers[done.book.id], width: 60, height: 88, radius: 5)
                VStack(alignment: .leading, spacing: 8) {
                    StageSteps(steps: steps, paused: false)
                    Text(loc.t("notify.done", done.book.title)).font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 7) {
                        Image(systemName: CheckStyle.symbol(level)).foregroundStyle(CheckStyle.color(level))
                        Text(CheckStyle.verdict(done.report, loc)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button(loc.t("common.close")) { model.finished = nil }.buttonStyle(GhostButtonStyle())
                        Button(loc.t("check.see")) { model.finished = nil; openResult(done.folder) }.buttonStyle(PrimaryButtonStyle(radius: 8))
                    }
                }
            }
            .padding(18)
        }
    }

    private func dotColor(_ i: Int, book: QueueBook, tint: Color) -> Color {
        if i < book.volume { return Theme.green }
        if i == book.volume { return tint }
        return Theme.dotIdle
    }

    @ViewBuilder private var engineLine: some View {
        if let switched = model.switchedEngine, let main = model.mainEngine {
            statusDot(loc.t("process.engine.switched", switched, main.label), Theme.warnIcon)
        } else if let main = model.mainEngine {
            let backups = model.backupEngines.map(\.label).joined(separator: ", ")
            statusDot(backups.isEmpty ? loc.t("process.engine.mainOnly", main.label)
                                      : loc.t("process.engine.main", main.label, backups), Theme.muted)
        }
    }

    private func statusDot(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }
            .font(.system(size: 12)).foregroundStyle(color)
    }

    private func etaText(paused: Bool) -> String {
        paused ? loc.t("process.eta.paused") : model.etaDescription(loc)
    }

    // MARK: - Queue

    private var queueTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(loc.t("process.queue")).font(.system(size: 14, weight: .semibold))
                Text(loc.t("process.queueHint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            CardBox {
                VStack(spacing: 0) {
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { index, book in
                        QueueRow(book: book, position: index + 1)
                        if index < waiting.count - 1 { Rectangle().fill(Theme.rowLine).frame(height: 1) }
                    }
                }
            }
        }
    }
}

/// The way of a book above its title: glossary and style, translation, polish, each with its time.
struct StageSteps: View {
    @Environment(Loc.self) private var loc
    var steps: [BookStage]
    var paused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { row(0..<steps.count) }
            VStack(alignment: .leading, spacing: 6) {          // a narrow window: two to a line
                ForEach(Array(stride(from: 0, to: steps.count, by: 2)), id: \.self) { first in
                    HStack(spacing: 6) { row(first..<min(first + 2, steps.count)) }
                }
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder private func row(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { index in
            chip(steps[index], number: index + 1)
            if index < range.upperBound - 1 {
                Rectangle().fill(steps[index].state == .done ? Theme.stageIdle : Theme.stageTrack).frame(width: 14, height: 2)
            }
        }
    }

    private func chip(_ step: BookStage, number: Int) -> some View {
        let active = step.state == .active
        let glowing = active && !paused
        return HStack(spacing: 7) {
            Image(systemName: symbol(step.state)).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glowing ? Theme.glowLine : (active ? Theme.amber : Theme.stageIdle))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(number). \(loc.t("stage.\(step.id)"))").font(.system(size: 12.5, weight: active ? .semibold : .medium))
                Text(note(step)).font(.system(size: 11)).opacity(0.85).monospacedDigit()
            }
            .lineLimit(1).fixedSize()
        }
        .foregroundStyle(glowing ? Theme.glowText : (active ? Theme.warnText : Theme.faint))
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(glowing ? Theme.glowBg : (active ? Theme.warnBg : (step.state == .done ? Theme.neutralBg : .clear)),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(glowing ? Theme.glowLine : (step.state == .done ? .clear : Theme.stageTrack),
                                        style: StrokeStyle(lineWidth: glowing ? 1.5 : 1,
                                                           dash: step.state == .skipped ? [4, 3] : [])))
        .shadow(color: glowing ? Theme.glowLine.opacity(0.55) : .clear, radius: 7)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ state: BookStage.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .active: return paused ? "pause.circle.fill" : "largecircle.fill.circle"
        case .pending: return "circle"
        case .skipped: return "minus.circle"
        }
    }

    private func note(_ step: BookStage) -> String {
        if step.state == .skipped { return loc.t("stage.skipped") }
        let spent = step.seconds > 0 ? loc.duration(step.seconds) : ""
        let word: String
        switch step.state {
        case .done: word = loc.t("stage.done")
        case .active: word = loc.t(paused ? "stage.paused" : "stage.running")
        default: word = loc.t("stage.waiting")
        }
        return spent.isEmpty ? word : "\(word) · \(spent)"
    }
}

struct ProgressBar: View {
    var value: Double
    var tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.trackBar)
                Capsule().fill(tint).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }.frame(height: 6)
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook
    var position: Int

    var body: some View {
        let review = book.stage == .needsReview
        let failed = book.stage == .failed
        HStack(spacing: 14) {
            Text("\(position)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.neutralText)
                .frame(width: 22, height: 22).background(Theme.numCircle, in: Circle())
            CoverView(title: book.title, image: model.queueCovers[book.id], width: 38, height: 54, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(book.author.isEmpty ? "" : book.author + " · ")\(loc.volumes(book.volumes)) · \(loc.t("input.about", loc.minutes(book.estimatedMinutes)))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                if failed, !book.error.isEmpty {
                    Text(book.error).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if failed { Pill(text: loc.t("process.failed"), bg: Theme.dangerBg, fg: Theme.danger, size: 12) }
            else if review { Pill(text: loc.t("process.reviewChip"), bg: Theme.warnBg, fg: Theme.warnText, size: 12) }
            else if book.stage == .preparing { Pill(text: loc.t("process.preparingChip"), bg: Theme.warnBg, fg: Theme.warnText, size: 12) }
            else { Pill(text: loc.t("process.waitTurn"), bg: Theme.neutralBg, fg: Theme.queueText, size: 12) }
            if review {
                Button(loc.t("process.review")) { model.reviewTarget = book.id }.buttonStyle(PrimaryButtonStyle(radius: 8))
            }
            if failed {
                Button(loc.t("process.retry")) { model.retry(book.id) }.buttonStyle(GhostButtonStyle())
            }
            IconButton(symbol: "chevron.up", help: loc.t("input.up"), size: 28, enabled: model.canMove(book.id, by: -1)) { model.move(book.id, by: -1) }
            IconButton(symbol: "chevron.down", help: loc.t("input.down"), size: 28, enabled: model.canMove(book.id, by: 1)) { model.move(book.id, by: 1) }
            IconButton(symbol: "xmark", help: loc.t("input.toInput"), size: 28) { model.unready(book.id) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
