import SwiftUI

enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/aansun/NNAI-Translator")!
}

/// What the About window lists, as keys of the string table.
enum AboutContent {
    static let hood = (1...5).map { "about.hood.\($0)" }
    static let limits = (1...7).map { "about.limit.\($0)" }
}

/// The About window: who made it, how it works under the hood, what it cannot do yet, and where the code is.
struct AboutView: View {
    @Environment(Loc.self) private var loc

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                list(loc.t("about.hood.title"), AboutContent.hood)
                list(loc.t("about.limits.title"), AboutContent.limits)
                buy
                footer
            }
            .padding(24)
        }
        .frame(width: 540, height: 680)
        .background(Theme.window)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("NNAI Translator").font(.system(size: 22, weight: .semibold))
            Text(loc.t("about.version", Updater.currentVersion, Updater.currentBuild)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Link(loc.t("about.github"), destination: AboutPanel.repositoryURL).font(.system(size: 13)).padding(.top, 2)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 4)
    }

    private func list(_ title: String, _ keys: [String]) -> some View {
        CardBox(radius: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                ForEach(keys, id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}").foregroundStyle(Theme.faint)
                        Text(loc.t(key)).font(.system(size: 12.5)).foregroundStyle(Theme.neutralText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var buy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.t("about.buy.title")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.warnText)
            Text(loc.t("about.buy.body")).font(.system(size: 12.5)).foregroundStyle(Theme.warnText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(loc.t("about.license")).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AboutMenuButton: View {
    @Environment(Loc.self) private var loc
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(loc.t("about.menu")) {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
