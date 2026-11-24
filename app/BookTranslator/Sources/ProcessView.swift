import SwiftUI

/// Step 2: the book that runs now, the queue behind it, and the books that wait for review.
struct ProcessView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var goInput: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.readyList.isEmpty {
                    empty
                } else {
                    if let running = model.running { runningCard(running) } else if model.paused { pausedCard }
                    queueCard
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(loc.t("process.empty")).font(.title3.weight(.semibold))
            Text(loc.t("process.emptyHint")).foregroundStyle(.secondary)
            Button(loc.t("process.goInput"), action: goInput).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var pausedCard: some View {
        CardContainer(title: loc.t("process.paused")) {
            Button(loc.t("process.resume")) { model.resume() }.buttonStyle(.borderedProminent)
        }.frame(height: 110)
    }

    private func runningCard(_ book: QueueBook) -> some View {
        let preparing = book.stage == .preparing
        let overall = book.volumes > 0 ? Double(max(book.volume - 1, 0) * 100 + book.pct) / Double(book.volumes * 100) : 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                CoverTile(title: book.title, image: nil, width: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("process.now")).font(.caption).foregroundStyle(.secondary)
                    Text(book.title).font(.custom("Georgia", size: 22).weight(.semibold))
                    HStack(spacing: 6) {
                        KindChip(kind: book.kind)
                        if let engine = model.status?.engine.nonEmpty { Chip(text: loc.t("process.via", engine), tint: Theme.accent) }
                    }
                }
                Spacer()
                Button(loc.t("process.pause")) { model.pause() }
            }
            if preparing {
                HStack { ProgressView().controlSize(.small); Text(loc.t("process.preparing")).foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(loc.t("process.volumeOf", max(book.volume, 1), book.volumes)).font(.callout.weight(.medium))
                        Spacer()
                        if let minutes = model.remainingMinutes {
                            Text(loc.t("process.remaining", loc.minutes(minutes))).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: overall).tint(Theme.accent)
                    HStack {
                        Text(loc.t("process.thisVolume")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(book.pct)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.logLine.isEmpty {
                Text(model.logLine).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.10)))
    }

    private var queueCard: some View {
        let rest = model.readyList.filter { $0.id != model.runningID }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("process.queue")).font(.headline)
                Text(loc.t("process.queueHint")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rest.enumerated()), id: \.element.id) { index, book in
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.body.weight(.medium))
                        Text("\(loc.t(book.kind.key)) · \(loc.t("input.about", loc.minutes(book.estimatedMinutes)))")
                            .font(.caption).foregroundStyle(.secondary)
                        if book.stage == .failed, !book.error.isEmpty {
                            Text(book.error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    chip(for: book)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.10)))
    }

    @ViewBuilder private func chip(for book: QueueBook) -> some View {
        switch book.stage {
        case .needsReview:
            Button(loc.t("process.review")) { model.reviewTarget = book.id }.buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Button(loc.t("process.retry")) { model.retry(book.id) }.controlSize(.small)
        case .preparing: Chip(text: loc.t("process.preparing").components(separatedBy: ":")[0], tint: .orange)
        default: Chip(text: loc.t("process.waiting"))
        }
    }
}
