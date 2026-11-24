import Foundation
import AppKit

/// The metadata of an EPUB as the user needs to verify it. Read straight from the package
/// document (OPF) with `unzip`, so the screen shows what is really in the file.
struct EpubMetadata: Equatable {
    var title = ""
    var creators: [String] = []
    var language = ""
    var description = ""
    var publisher = ""
    var date = ""
    var subjects: [String] = []
    var identifier = ""
    var source = ""
    var series = ""
    var seriesIndex = ""
    var coverHref: String?
    var opfPath = ""

    var hasCover: Bool { coverHref != nil }
}

enum EpubReader {
    static func unzip(_ epub: URL, entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", epub.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    static func opfPath(in epub: URL) -> String? {
        guard let data = unzip(epub, entry: "META-INF/container.xml") else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"full-path="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match.replacingOccurrences(of: "full-path=\"", with: "").replacingOccurrences(of: "\"", with: "")
    }

    static func read(_ epub: URL) -> EpubMetadata? {
        guard let path = opfPath(in: epub), let data = unzip(epub, entry: path) else { return nil }
        var meta = parse(opf: data)
        meta.opfPath = path
        return meta
    }

    static func parse(opf data: Data) -> EpubMetadata {
        let parser = XMLParser(data: data)
        let delegate = OPFDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
    }

    /// The cover image of the EPUB, if it has one.
    static func cover(_ epub: URL) -> NSImage? {
        guard let meta = read(epub), let href = meta.coverHref else { return nil }
        let base = (meta.opfPath as NSString).deletingLastPathComponent
        let entry = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
        let decoded = entry.removingPercentEncoding ?? entry
        guard let data = unzip(epub, entry: decoded) else { return nil }
        return NSImage(data: data)
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    private var meta = EpubMetadata()
    private var current = ""
    private var text = ""
    private var collectionProperty = false
    private var coverId: String?
    private var manifest: [String: String] = [:]
    private var coverFromProperty: String?

    func result() -> EpubMetadata {
        var out = meta
        if let id = coverId, let href = manifest[id] { out.coverHref = href }
        if out.coverHref == nil { out.coverHref = coverFromProperty }
        return out
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        current = name
        text = ""
        switch name {
        case "meta":
            if attributes["name"] == "cover" { coverId = attributes["content"] }
            if attributes["name"] == "calibre:series" { meta.series = attributes["content"] ?? "" }
            if attributes["name"] == "calibre:series_index" { meta.seriesIndex = attributes["content"] ?? "" }
            collectionProperty = attributes["property"] == "belongs-to-collection"
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
                if (attributes["properties"] ?? "").contains("cover-image") { coverFromProperty = href }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard !value.isEmpty else { return }
        switch name {
        case "dc:title": if meta.title.isEmpty { meta.title = value }
        case "dc:creator": meta.creators.append(value)
        case "dc:language": if meta.language.isEmpty { meta.language = value }
        case "dc:description": if meta.description.isEmpty { meta.description = value }
        case "dc:publisher": if meta.publisher.isEmpty { meta.publisher = value }
        case "dc:date": if meta.date.isEmpty { meta.date = value }
        case "dc:subject": meta.subjects.append(value)
        case "dc:identifier": if meta.identifier.isEmpty { meta.identifier = value }
        case "dc:source": if meta.source.isEmpty { meta.source = value }
        case "meta":
            if collectionProperty, meta.series.isEmpty { meta.series = value }
            collectionProperty = false
        default: break
        }
    }
}
