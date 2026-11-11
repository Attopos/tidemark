import Foundation
import Compression

// MARK: - Minimal .xlsx reader
//
// An .xlsx file is a zip of XML parts. This reads the first worksheet as rows
// of strings and nothing else: no styles, formulas or dates. It exists so a
// spreadsheet export can be imported without a third-party dependency.

enum XLSXError: LocalizedError {
    case notAZip
    case missingPart(String)
    case unsupportedCompression(Int)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "This file is not a valid .xlsx workbook."
        case .missingPart(let name): return "The workbook has no \(name)."
        case .unsupportedCompression(let method): return "Unsupported zip compression method \(method)."
        case .corrupt(let what): return "The workbook is damaged (\(what))."
        }
    }
}

// MARK: Zip

struct ZipArchive {
    private struct Entry {
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    var names: [String] { entries.keys.sorted() }

    init(data: Data) throws {
        self.data = data
        // End of central directory: scan backwards for its signature.
        let minimum = 22
        guard data.count >= minimum else { throw XLSXError.notAZip }
        var eocd = -1
        var index = data.count - minimum
        let lowest = max(0, data.count - minimum - 0xFFFF)
        while index >= lowest {
            if u32(index) == 0x0605_4b50 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw XLSXError.notAZip }
        let count = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x0201_4b50 else {
                throw XLSXError.corrupt("central directory")
            }
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw XLSXError.corrupt("entry name") }
            let name = String(decoding: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)), as: UTF8.self)
            entries[name] = Entry(method: Int(u16(offset + 10)),
                                  compressedSize: Int(u32(offset + 20)),
                                  uncompressedSize: Int(u32(offset + 24)),
                                  localHeaderOffset: Int(u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries[name] else { throw XLSXError.missingPart(name) }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(header) == 0x0403_4b50 else { throw XLSXError.corrupt(name) }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressedSize <= data.count else { throw XLSXError.corrupt(name) }
        let body = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return body
        case 8:
            if entry.uncompressedSize == 0 { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                body.withUnsafeBytes { source -> Int in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    // COMPRESSION_ZLIB is raw DEFLATE, which is what zip stores.
                    return compression_decode_buffer(dst, entry.uncompressedSize, src, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw XLSXError.corrupt(name) }
            return output
        default:
            throw XLSXError.unsupportedCompression(entry.method)
        }
    }

    private func u16(_ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}

// MARK: Workbook

enum XLSXReader {
    /// Rows of the first worksheet. Missing cells are empty strings; every
    /// row is as wide as its last filled cell.
    static func firstSheetRows(of data: Data) throws -> [[String]] {
        let zip = try ZipArchive(data: data)
        let sheets = zip.names
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        guard let sheet = sheets.first else { throw XLSXError.missingPart("worksheet") }
        var shared: [String] = []
        if zip.names.contains("xl/sharedStrings.xml") {
            shared = SharedStringsParser.parse(try zip.contents(of: "xl/sharedStrings.xml"))
        }
        return SheetParser.parse(try zip.contents(of: sheet), shared: shared)
    }

    static func firstSheetRows(at url: URL) throws -> [[String]] {
        try firstSheetRows(of: try Data(contentsOf: url))
    }

    /// "A" → 0, "Z" → 25, "AA" → 26.
    static func columnIndex(ofReference reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(0, index - 1)
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [[String]] = []
    private var row: [String] = []
    private var column = 0
    private var cellType = ""
    private var text = ""
    private var capturing = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let delegate = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            row = []
        case "c":
            column = attributes["r"].map(XLSXReader.columnIndex(ofReference:)) ?? row.count
            cellType = attributes["t"] ?? ""
            text = ""
        case "v", "t":
            capturing = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            capturing = false
        case "c":
            var value = text
            if cellType == "s", let index = Int(text), shared.indices.contains(index) { value = shared[index] }
            while row.count < column { row.append("") }
            if row.count == column { row.append(value) } else { row[column] = value }
        case "row":
            rows.append(row)
        default:
            break
        }
    }
}
