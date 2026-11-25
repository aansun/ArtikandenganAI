import AppKit

/// The About window: the standard panel with a short description and a link to the project on GitHub.
enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/aansun/ArtikandenganAI")!

    static func credits(_ loc: Loc) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                    .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: loc.t("about.blurb") + "\n", attributes: base)
        text.append(NSAttributedString(string: loc.t("about.source") + ": ", attributes: base))
        var link = base
        link[.link] = repositoryURL
        link[.foregroundColor] = NSColor.linkColor
        text.append(NSAttributedString(string: "github.com/aansun/ArtikandenganAI", attributes: link))
        return text
    }

    @MainActor static func show(_ loc: Loc) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NNAI Translator", .credits: credits(loc)])
    }
}
