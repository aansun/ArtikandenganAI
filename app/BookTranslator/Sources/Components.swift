import SwiftUI

enum Theme {
    static let accent = Color(red: 0, green: 0.4, blue: 0.84)
    static let warnBackground = Color(red: 1, green: 0.945, blue: 0.84)
    static let warnText = Color(red: 0.54, green: 0.35, blue: 0)
    static let okBackground = Color(red: 0.906, green: 0.953, blue: 0.918)
    static let serif = Font.custom("Georgia", size: 15)
}

struct Chip: View {
    var text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct KindChip: View {
    @Environment(Loc.self) private var loc
    var kind: BookKind
    var body: some View { Chip(text: loc.t(kind.key), tint: kind == .fiction ? .purple : .teal) }
}

/// A generated cover for books without one: colour from the title, serif initials.
struct CoverTile: View {
    var title: String
    var image: NSImage?
    var width: CGFloat = 64

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [tint(0.55), tint(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(initials)
                        .font(.custom("Georgia", size: width * 0.34).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: width, height: width * 1.45)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private var initials: String {
        let words = title.split(separator: " ").filter { !["the", "a", "an", "of"].contains($0.lowercased()) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private func tint(_ brightness: Double) -> Color {
        let hue = Double(abs(title.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: brightness + 0.3)
    }
}

struct CardContainer<Content: View>: View {
    var title: String
    var subtitle: String = ""
    var trailing: AnyView = AnyView(EmptyView())
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.10)))
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View { Text(text).font(.title2.weight(.semibold)) }
}
