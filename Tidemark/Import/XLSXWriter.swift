import Foundation
import Compression

// MARK: - Minimal .xlsx writer
//
// One worksheet: text cells as shared strings (index 0 is the empty string),
// chosen columns as numbers.

struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    mutating func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(content)
        let deflated = Self.deflate(content)
        let method: UInt16 = deflated == nil ? 0 : 8
        let stored = deflated ?? content
        let offset = UInt32(body.count)

        var local = Data()
        local.append(le32: 0x0403_4b50)
        local.append(le16: 20)
        local.append(le16: 0x0800)
        local.append(le16: method)
        local.append(le16: 0)
        local.append(le16: 0x21)
        local.append(le32: crc)
        local.append(le32: UInt32(stored.count))
        local.append(le32: UInt32(content.count))
        local.append(le16: UInt16(nameData.count))
        local.append(le16: 0)
        body.append(local)
        body.append(nameData)
        body.append(stored)

        directory.append(le32: 0x0201_4b50)
        directory.append(le16: 20)
        directory.append(le16: 20)
        directory.append(le16: 0x0800)
        directory.append(le16: method)
        directory.append(le16: 0)
        directory.append(le16: 0x21)
        directory.append(le32: crc)
        directory.append(le32: UInt32(stored.count))
        directory.append(le32: UInt32(content.count))
        directory.append(le16: UInt16(nameData.count))
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le16: 0)
        directory.append(le32: 0)
        directory.append(le32: offset)
        directory.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var data = body
        data.append(directory)
        data.append(le32: 0x0605_4b50)
        data.append(le16: 0)
        data.append(le16: 0)
        data.append(le16: UInt16(count))
        data.append(le16: UInt16(count))
        data.append(le32: UInt32(directory.count))
        data.append(le32: UInt32(body.count))
        data.append(le16: 0)
        return data
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        append(le16: UInt16(value & 0xFFFF))
        append(le16: UInt16(value >> 16))
    }
}

enum XLSXWriter {
    static func workbook(sheetName: String, rows: [[String]], numericColumns: Set<Int> = []) -> Data {
        var strings = [""]
        var lookup = ["": 0]
        func index(_ text: String) -> Int {
            if let found = lookup[text] { return found }
            strings.append(text)
            lookup[text] = strings.count - 1
            return strings.count - 1
        }

        let width = rows.map(\.count).max() ?? 0
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <dimension ref="A1:\(columnName(max(width, 1) - 1))\(max(rows.count, 1))"/>\
        <sheetViews><sheetView workbookViewId="0"/></sheetViews>\
        <sheetFormatPr customHeight="1" defaultColWidth="12.63" defaultRowHeight="15.75"/>\
        <cols><col min="1" max="16384" width="9.9996096" customWidth="1" style="0"/></cols><sheetData>
        """
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\" spans=\"1:\(width)\">"
            for c in 0..<width {
                let text = c < row.count ? row[c] : ""
                let style = r == 0 && c == 0 ? 1 : 2
                let reference = "\(columnName(c))\(r + 1)"
                if r > 0, numericColumns.contains(c), !text.isEmpty, Decimal(string: text) != nil {
                    sheet += "<c r=\"\(reference)\" s=\"\(style)\"><v>\(text)</v></c>"
                } else {
                    sheet += "<c r=\"\(reference)\" s=\"\(style)\" t=\"s\"><v>\(index(text))</v></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        var shared = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" uniqueCount="\(strings.count)">
        """
        for text in strings {
            let space = text != text.trimmingCharacters(in: .whitespacesAndNewlines) ? " xml:space=\"preserve\"" : ""
            shared += "<si><t\(space)>\(escape(text))</t></si>"
        }
        shared += "</sst>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rootRels.utf8))
        zip.add("xl/workbook.xml", Data(workbookXML(sheetName: sheetName).utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8))
        zip.add("xl/styles.xml", Data(styles.utf8))
        zip.add("xl/sharedStrings.xml", Data(shared.utf8))
        zip.add("xl/worksheets/sheet1.xml", Data(sheet.utf8))
        return zip.finish()
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&#x27;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default ContentType="application/xml" Extension="xml"/>\
    <Default ContentType="application/vnd.openxmlformats-package.relationships+xml" Extension="rels"/>\
    <Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml" PartName="/xl/worksheets/sheet1.xml"/>\
    <Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml" PartName="/xl/sharedStrings.xml"/>\
    <Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml" PartName="/xl/styles.xml"/>\
    <Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml" PartName="/xl/workbook.xml"/>\
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static func workbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <workbookPr/><sheets><sheet state="visible" name="\(escape(sheetName))" sheetId="1" r:id="rId4"/></sheets>\
        <definedNames/><calcPr/></workbook>
        """
    }

    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>\
    <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
    </Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="0"/><fonts count="3">\
    <font><sz val="10"/><color rgb="FF000000"/><name val="Arial"/></font>\
    <font><sz val="10"/><color rgb="FF000000"/><name val="TrebuchetMS"/></font>\
    <font><sz val="10"/><color rgb="FF000000"/><name val="TrebuchetMS"/></font></fonts>\
    <fills count="1"><fill><patternFill patternType="solid"><fgColor rgb="FFFFFFFF"/><bgColor indexed="64"/></patternFill></fill></fills>\
    <borders count="1"><border/></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="3">\
    <xf fontId="0" numFmtId="0" fillId="0" borderId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>\
    <xf fontId="1" numFmtId="0" fillId="0" borderId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>\
    <xf fontId="2" numFmtId="0" fillId="0" borderId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>\
    </cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/></styleSheet>
    """
}
