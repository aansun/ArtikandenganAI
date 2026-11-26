import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }

    /// A colour that follows the window's appearance (light or dark).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// Soft, warm colours, each with a light and a dark value.
enum Theme {
    static let window = Color(light: 0xF9F4EE, dark: 0x1F1B18)
    static let bar = Color(light: 0xF2EAE0, dark: 0x29241F)
    static let barLine = Color(light: 0xE5D9CB, dark: 0x3D362F)
    static let card = Color(light: 0xFFFCF8, dark: 0x2B2621)
    static let line = Color(light: 0xEADFD2, dark: 0x3E372F)
    static let rowLine = Color(light: 0xF2EAE0, dark: 0x38312A)
    static let ink = Color(light: 0x2F2721, dark: 0xF4ECE3)
    static let muted = Color(light: 0x6B5E53, dark: 0xB5A79A)
    static let faint = Color(light: 0x837467, dark: 0x9A8C7F)
    static let accent = Color(light: 0xAE5630, dark: 0xE59A72)
    static let accentDark = Color(light: 0x8C4020, dark: 0xF0B596)
    static let green = Color(light: 0x55775A, dark: 0x98BC92)
    static let okBg = Color(light: 0xE8F0E2, dark: 0x2B3627)
    static let okText = Color(light: 0x3F5F3B, dark: 0xB2D1A8)
    static let warnBg = Color(light: 0xFBEED5, dark: 0x40321B)
    static let warnText = Color(light: 0x7A5211, dark: 0xF0C97D)
    static let warnIcon = Color(light: 0x8C5F16, dark: 0xE2B568)
    static let amber = Color(light: 0xC18535, dark: 0xDFA95C)
    static let readyBg = Color(light: 0xFBF0E7, dark: 0x342820)
    static let readyLine = Color(light: 0xEFD5C0, dark: 0x5A4333)
    static let dashed = Color(light: 0xDBC1AA, dark: 0x6B5647)
    static let segTrack = Color(light: 0xEFE5DA, dark: 0x3D362F)
    static let selectedSeg = Color(light: 0xFFFCF8, dark: 0x6A5C50)
    static let buttonLine = Color(light: 0xD8C9BA, dark: 0x5C5248)
    static let fictionBg = Color(light: 0xF8E7DC, dark: 0x463122)
    static let neutralBg = Color(light: 0xF1E9E0, dark: 0x3D362F)
    static let neutralText = Color(light: 0x47392F, dark: 0xDDD0C3)
    static let divider = Color(light: 0xEBE1D5, dark: 0x3E372F)
    static let subtleDivider = Color(light: 0xF5EEE6, dark: 0x38312A)
    static let fieldBorder = Color(light: 0xDCCFC1, dark: 0x574D44)
    static let rowBorder = Color(light: 0xF0E7DD, dark: 0x3E372F)
    static let readyRowBorder = Color(light: 0xEDD7C5, dark: 0x66493A)
    static let dropFill = Color(light: 0xFDF8F2, dark: 0x2E2620)
    static let selectedFill = Color(light: 0xFCEFE5, dark: 0x402F23)
    static let unselectedBorder = Color(light: 0xE8DDD1, dark: 0x4C443C)
    static let grip = Color(light: 0xC1B1A2, dark: 0x7A6C60)
    static let dotIdle = Color(light: 0xE2D6CA, dark: 0x4C443C)
    static let trackBar = Color(light: 0xEDE3D8, dark: 0x3D362F)
    static let numCircle = Color(light: 0xEFE5DA, dark: 0x4C443C)
    static let stageTrack = Color(light: 0xE8DCCF, dark: 0x3A332D)
    static let stageIdle = Color(light: 0xC3B3A4, dark: 0x75675B)
    static let sidePanel = Color(light: 0xFCF8F3, dark: 0x25201C)
    static let queueText = Color(light: 0x55473B, dark: 0xDDD0C3)
    static let codexBadge = Color(light: 0x4A3F36, dark: 0x6A5C50)
    static let onAccent = Color(light: 0xFFFBF7, dark: 0x2A170B)     // text on a filled accent
    static let danger = Color(light: 0xA9443A, dark: 0xE99388)
    static let dangerBg = Color(light: 0xF8E4E0, dark: 0x43241F)
    static let glowBg = Color(light: 0xFFDDB5, dark: 0x6A4220)       // the stage at work
    static let glowLine = Color(light: 0xF29A4A, dark: 0xFFB066)
    static let glowText = Color(light: 0x6E3405, dark: 0xFFE3C4)
    static let engineBlue = Color(light: 0x5F7F9C, dark: 0x7C9CB8)
    static let engineGrey = Color(light: 0x8A7B6E, dark: 0x82756A)
}

struct Pill: View {
    var text: String
    var bg: Color
    var fg: Color
    var size: CGFloat = 11
    var body: some View {
        Text(text).font(.system(size: size, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 2.5).background(bg, in: Capsule())
    }
}

extension BookKind {
    var pillBg: Color { self == .fiction ? Theme.fictionBg : Theme.neutralBg }
    var pillFg: Color { self == .fiction ? Theme.accentDark : Theme.neutralText }
}

/// The macOS-style segmented control of the design (grey track, white selected segment).
struct Segmented<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T
    var fontSize: CGFloat = 12
    var hPad: CGFloat = 11
    var vPad: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let (value, label) = items[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(label).font(.system(size: fontSize)).foregroundStyle(on ? Theme.ink : Theme.muted)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, hPad).padding(.vertical, vPad)
                        .background(on ? Theme.selectedSeg : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 1, y: 1)
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Theme.segTrack, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var radius: CGFloat = 9
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(configuration.isPressed ? fill.opacity(0.8) : fill, in: RoundedRectangle(cornerRadius: radius))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    var bordered = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5)).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(configuration.isPressed ? Color.black.opacity(0.06) : (bordered ? Theme.card : .clear), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(bordered ? Theme.buttonLine : .clear))
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 26
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.neutralText)
                .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3).help(help)
    }
}

enum Covers {
    private static let palette: [(UInt32, UInt32)] = [
        (0x1F4E5A, 0x0D2730), (0x4A5F8A, 0x252F4A), (0x5B4A78, 0x2A2140), (0x6B7A45, 0x35401F), (0x8A2F3A, 0x431219),
        (0xB8742A, 0x5C3410), (0x4D5560, 0x262B32), (0x2F6A62, 0x123430), (0x6A3A2A, 0x2E1710), (0x3A4A3A, 0x161D16),
        (0xB86A86, 0x5A2A40), (0x2A6A8A, 0x10303F), (0x8A7A5A, 0x3F3622), (0x5A7A4A, 0x27381F),
    ]

    /// A stable pick from the title (String.hashValue changes at every launch).
    static func gradient(for title: String) -> LinearGradient {
        var h: UInt64 = 5381
        for byte in title.utf8 { h = (h &* 33) &+ UInt64(byte) }
        let pair = palette[Int(h % UInt64(palette.count))]
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
    }
}

/// A cover: the book's own image when it has one, else a gradient (with the title if asked).
struct CoverView: View {
    var title: String
    var image: NSImage? = nil
    var width: CGFloat
    var height: CGFloat
    var showTitle = false
    var radius: CGFloat = 4

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: height).clipped()
            } else {
                Rectangle().fill(Covers.gradient(for: title))
                if showTitle {
                    Text(title).font(.custom("Georgia", size: max(10.5, width * 0.095))).foregroundStyle(.white).lineLimit(5)
                        .padding(7).multilineTextAlignment(.leading)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.22), radius: width > 80 ? 6 : 2.5, y: width > 80 ? 3 : 1.5)
    }
}

struct CardBox<Content: View>: View {
    var fill: Color = Theme.card
    var border: Color = Theme.line
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content.background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}


/// A cover looked up from several sources, cached, with a spinner while it loads and a clear fallback.
struct RemoteImage: View {
    var urls: [URL]
    var title: String
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 4
    @State private var image: NSImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Covers.gradient(for: title).opacity(0.55))
                if urls.isEmpty || failed {
                    Image(systemName: "photo").font(.system(size: min(width, height) * 0.3)).foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: width, height: height).clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .task(id: urls) { await load() }
    }

    private func load() async {
        image = nil; failed = false
        guard !urls.isEmpty else { return }
        let key = urls.map(\.absoluteString).joined(separator: "|") as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        if let data = await CoverFetcher.fetch(urls), let loaded = NSImage(data: data) {
            Self.cache.setObject(loaded, forKey: key)
            image = loaded
        } else {
            failed = true
        }
    }
}
