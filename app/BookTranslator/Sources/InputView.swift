import SwiftUI
import UniformTypeIdentifiers

/// Step 1: upload many books on the left, drag the ones to translate to the right.
struct InputView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    @State private var dropping = false
    @State private var readyDropping = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                uploadedCard
                readyCard
            }
            startBar
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Left card

    private var uploadedCard: some View {
        CardContainer(
            title: loc.t("input.uploaded"),
            subtitle: loc.t("input.count", model.uploaded.count),
            trailing: AnyView(Button(loc.t("input.readyAll")) { model.makeAllReady() }
                .disabled(!model.uploaded.contains { $0.stage == .uploaded }))
        ) {
            dropZone
            if model.uploaded.isEmpty {
                Text(loc.t("input.allReady")).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.uploaded) { UploadedRow(book: $0) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.addFiles(urls); return true } isTargeted: { dropping = $0 }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: dropping ? 2 : 0))
    }

    private var dropZone: some View {
        HStack {
            Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(Theme.accent)
            Text(loc.t("input.dropHint")).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(loc.t("input.choose")) { choose() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
            .foregroundStyle(Color.secondary.opacity(0.5)))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "epub"), .plainText].compactMap { $0 }
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    // MARK: - Right card

    private var readyCard: some View {
        CardContainer(title: loc.t("input.ready"), subtitle: loc.t("input.readyHint"),
                      trailing: AnyView(Text("\(model.readyList.count)").font(.title3.monospacedDigit()).foregroundStyle(.secondary))) {
            if model.readyList.isEmpty {
                Text(loc.t("input.readyEmpty")).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.readyList.enumerated()), id: \.element.id) { index, book in
                        ReadyRow(book: book, position: index + 1)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { model.moveReady(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            for item in items { if let id = UUID(uuidString: item) { model.makeReady(id) } }
            return true
        } isTargeted: { readyDropping = $0 }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: readyDropping ? 2 : 0))
    }

    private var startBar: some View {
        HStack {
            if let error = model.lastError.nonEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warnText)
                    .lineLimit(2)
            }
            Spacer()
            let waiting = model.waitingCount
            Button {
                model.start()
            } label: {
                Text(waiting > 1 ? loc.t("input.startN", waiting) : loc.t("input.start")).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(waiting == 0 || model.isBusy)
        }
    }
}

private struct UploadedRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook

    var body: some View {
        HStack(spacing: 12) {
            CoverTile(title: book.title, width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if book.stage == .reading {
                ProgressView().controlSize(.small)
                Text(loc.t("input.reading")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.toggleKind(book.id) } label: { KindChip(kind: book.kind) }
                    .buttonStyle(.plain).help(loc.t("input.toggleKind", loc.t(book.kind.other.key)))
                Button(loc.t("input.prepare")) { model.makeReady(book.id) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .draggable(book.id.uuidString)
        .contextMenu { Button(loc.t("input.remove"), role: .destructive) { model.remove(book.id) } }
    }

    private var subtitle: String {
        guard book.stage != .reading else { return "" }
        let volumes = book.volumes > 1 ? loc.t("input.volumes", book.volumes) : loc.t("input.volume1")
        return [book.author, volumes].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ReadyRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc
    var book: QueueBook
    var position: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(loc.t(book.kind.key)) · \(book.volumes > 1 ? loc.t("input.volumes", book.volumes) : loc.t("input.volume1")) · \(loc.t("input.about", loc.minutes(book.estimatedMinutes)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if book.stage == .translating || book.stage == .preparing {
                ProgressView().controlSize(.small)
            } else if book.stage == .failed {
                Chip(text: loc.t("process.failed"), tint: .red)
            }
        }
        .padding(8)
        .contextMenu {
            Button(loc.t("input.moveFirst")) { model.moveFirst(book.id) }
            if book.kind == .fiction {
                Toggle(loc.t("input.reviewFirst"), isOn: Binding(get: { book.reviewFirst }, set: { model.setReviewFirst(book.id, $0) }))
            }
            Button(loc.t("input.backToUploaded")) { model.unready(book.id) }
                .disabled(book.stage != .ready && book.stage != .failed)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
