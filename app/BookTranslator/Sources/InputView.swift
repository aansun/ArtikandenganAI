import SwiftUI
import UniformTypeIdentifiers

/// Step 1, as in the design: uploaded books (white card) and ready books in order (blue card),
/// with a bottom bar that starts the translation.
struct InputView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var onStart: () -> Void
    @State private var overUploaded = false
    @State private var overReady = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) { uploadedCard; readyCard }
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 16)
            bottomBar
        }
        .background(Theme.window)
    }

    // MARK: - Uploaded

    private var uploadedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                (Text(loc.t("input.uploaded")).font(.system(size: 15, weight: .semibold))
                 + Text(" · \(model.uploaded.count)").font(.system(size: 15)).foregroundColor(Theme.muted))
                Spacer()
                Button(loc.t("input.readyAll")) { model.makeAllReady() }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accent, bordered: false))
                    .disabled(!model.uploaded.contains { $0.stage == .uploaded })
            }
            dropZone
            ScrollView {
                VStack(spacing: 8) {
                    if model.uploaded.isEmpty {
                        Text(loc.t("input.allReady")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center).padding(.vertical, 24).frame(maxWidth: .infinity)
                    }
                    ForEach(model.uploaded) { UploadedRow(book: $0) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(overUploaded ? Theme.accent : Theme.line, lineWidth: overUploaded ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in model.addFiles(urls); return true } isTargeted: { overUploaded = $0 }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { if let uuid = UUID(uuidString: id) { model.unready(uuid) } }
            return true
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.to.line").font(.system(size: 18, weight: .regular)).foregroundStyle(Theme.accent)
            (Text(loc.t("input.dropBold")).font(.system(size: 13, weight: .bold))
             + Text(loc.t("input.dropRest")).font(.system(size: 13)).foregroundColor(Theme.muted))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(loc.t("input.choose")) { choose() }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity).frame(height: 66)
        .background(Theme.dropFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "epub"), .plainText].compactMap { $0 }
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    // MARK: - Ready

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(loc.t("input.ready")).font(.system(size: 15, weight: .semibold))
                 + Text(" · \(model.readyList.count)").font(.system(size: 15)).foregroundColor(Theme.muted))
                Text(loc.t("input.readyHint")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if model.readyList.isEmpty {
                        Text(loc.t("input.readyEmpty")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center).padding(20)
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    }
                    ForEach(Array(model.readyList.enumerated()), id: \.element.id) { index, book in
                        ReadyRow(book: book, position: index + 1)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.readyBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(overReady ? Theme.accent : Theme.readyLine, lineWidth: overReady ? 2 : 1))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { if let uuid = UUID(uuidString: id) { model.makeReady(uuid) } }
            return true
        } isTargeted: { overReady = $0 }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        let ready = model.readyList
        let volumes = ready.reduce(0) { $0 + $1.volumes }
        let minutes = ready.reduce(0) { $0 + $1.estimatedMinutes }
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ready.isEmpty ? loc.t("input.readyNone") : (ready.count == 1 ? loc.t("input.readyTitle1") : loc.t("input.readyTitle", ready.count)))
                    .font(.system(size: 14, weight: .semibold))
                Text(ready.isEmpty ? loc.t("input.readyDragHint")
                        : loc.t("input.readySub", volumes, loc.minutes(minutes)) + (ready.contains { $0.kind == .fiction } ? loc.t("input.readySubFiction") : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let error = model.lastError.nonEmpty {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warnIcon).lineLimit(2).frame(maxWidth: 280, alignment: .trailing)
            }
            Button(loc.t("input.start")) { model.startReady(); onStart() }
                .buttonStyle(PrimaryButtonStyle()).disabled(ready.isEmpty)
                .opacity(ready.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 28).frame(height: 68)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.barLine).frame(height: 1) }
    }
}

struct GripDots: View {
    var body: some View {
        Canvas { context, _ in
            for x in [3.0, 9.0] { for y in [3.0, 8.0, 13.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)), with: .color(Theme.grip))
            } }
        }.frame(width: 12, height: 16)
    }
}

private struct UploadedRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook

    var body: some View {
        HStack(spacing: 12) {
            GripDots()
            CoverView(title: book.title, image: model.queueCovers[book.id], width: 34, height: 48, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if book.stage == .reading {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(loc.t("input.reading")) }
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                } else {
                    Text("\(book.author.isEmpty ? "" : book.author + " · ")\(loc.volumes(book.volumes))")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(book.kind == .fiction ? loc.t("input.hintFiction") : loc.t("input.hintNonfiction"))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if book.stage != .reading {
                Button { model.toggleKind(book.id) } label: {
                    HStack(spacing: 4) {
                        Text(loc.t(book.kind.key))
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy))
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(book.kind.pillFg)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(book.kind.pillBg, in: Capsule())
                }.buttonStyle(.plain).help(loc.t("input.kindHelp"))
                Button(loc.t("input.prepare")) { model.makeReady(book.id) }
                    .buttonStyle(GhostButtonStyle(tint: Theme.accent))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.rowBorder))
        .draggable(book.id.uuidString)
        .contextMenu { Button(loc.t("input.remove"), role: .destructive) { model.remove(book.id) } }
    }
}

private struct ReadyRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook
    var position: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
            CoverView(title: book.title, image: model.queueCovers[book.id], width: 34, height: 48, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("\(loc.t(book.kind.key)) · \(loc.volumes(book.volumes)) · \(loc.t("input.about", loc.minutes(book.estimatedMinutes)))")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "chevron.up", help: loc.t("input.up"), enabled: model.canMove(book.id, by: -1)) { model.move(book.id, by: -1) }
            IconButton(symbol: "chevron.down", help: loc.t("input.down"), enabled: model.canMove(book.id, by: 1)) { model.move(book.id, by: 1) }
            IconButton(symbol: "xmark", help: loc.t("input.toUploaded")) { model.unready(book.id) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.readyRowBorder))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .draggable(book.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { if let uuid = UUID(uuidString: id) {
                if model.book(uuid)?.stage == .uploaded { model.makeReady(uuid) }
                model.placeBefore(uuid, before: book.id)
            } }
            return true
        }
        .contextMenu {
            Toggle(loc.t("input.reviewFirst"), isOn: Binding(get: { model.reviewsFirst(book) }, set: { model.setReviewFirst(book.id, $0) }))
        }
    }
}
