import Foundation

/// Just enough of a TOML scanner to edit Codex's `config.toml` losslessly: it finds the top-level `notify`
/// assignment (before the first `[table]` header) as a byte range and parses TOML string arrays. Everything else in
/// the file is only skipped over, never re-serialized, so the rest of the file stays byte-for-byte unchanged.
enum CodexConfigTOML {
    struct ScanError: Error, Equatable {
        let offset: Int
        let reason: String
    }

    /// A top-level `key = value` statement. `lineStart..<lineEnd` covers the whole statement: leading indentation,
    /// every line of a multi-line value and any trailing comment, but not the final line break.
    struct Assignment: Equatable {
        let lineStart: Int
        let lineEnd: Int
        let valueStart: Int
        let valueEnd: Int
    }

    struct TopLevel: Equatable {
        var notify: Assignment?
        /// Where a new top-level line can go: the start of the first table header, moved up over the comment lines
        /// directly attached to it. nil when the file has no tables.
        var insertionOffset: Int?
    }

    static func scanTopLevel(_ bytes: [UInt8]) throws -> TopLevel {
        var cursor = Cursor(bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { cursor.i = 3 }
        var result = TopLevel()
        var commentBlockStart: Int?

        while !cursor.atEnd {
            let lineStart = cursor.i
            cursor.skipSpaces()
            guard let c = cursor.peek() else { break }
            switch c {
            case ASCII.lf:
                cursor.i += 1
                commentBlockStart = nil
            case ASCII.cr where cursor.peek(1) == ASCII.lf:
                cursor.i += 2
                commentBlockStart = nil
            case ASCII.hash:
                if commentBlockStart == nil { commentBlockStart = lineStart }
                cursor.skipComment()
                _ = try cursor.consumeLineEnd()
            case ASCII.lbracket:
                result.insertionOffset = commentBlockStart ?? lineStart
                return result
            default:
                commentBlockStart = nil
                let key = try cursor.parseKey()
                cursor.skipSpaces()
                guard cursor.peek() == ASCII.equals else { throw cursor.error("expected '=' after key") }
                cursor.i += 1
                cursor.skipSpaces()
                let valueStart = cursor.i
                try cursor.skipValue()
                let valueEnd = cursor.i
                cursor.skipSpaces()
                cursor.skipComment()
                let lineEnd = try cursor.consumeLineEnd()
                if key == ["notify"], result.notify == nil {
                    result.notify = Assignment(lineStart: lineStart, lineEnd: lineEnd, valueStart: valueStart, valueEnd: valueEnd)
                }
            }
        }
        return result
    }

    /// Parses a TOML array of basic (`"…"`, with escapes) and literal (`'…'`) strings. Multi-line strings, nested
    /// arrays and non-string values are rejected.
    static func parseStringArray(_ bytes: [UInt8], range: Range<Int>) throws -> [String] {
        var cursor = Cursor(Array(bytes[range]))
        guard cursor.peek() == ASCII.lbracket else { throw cursor.error("notify is not an array") }
        cursor.i += 1
        var values: [String] = []
        while true {
            cursor.skipTrivia()
            if cursor.peek() == ASCII.rbracket { cursor.i += 1; break }
            switch cursor.peek() {
            case ASCII.quote? where !cursor.isTripleQuote(ASCII.quote):
                values.append(try cursor.readBasicString())
            case ASCII.apostrophe? where !cursor.isTripleQuote(ASCII.apostrophe):
                values.append(try cursor.readLiteralString())
            default:
                throw cursor.error("notify elements must be single-line strings")
            }
            cursor.skipTrivia()
            if cursor.peek() == ASCII.comma { cursor.i += 1; continue }
            if cursor.peek() == ASCII.rbracket { cursor.i += 1; break }
            throw cursor.error("expected ',' or ']' in notify array")
        }
        cursor.skipTrivia()
        guard cursor.atEnd else { throw cursor.error("unexpected text after notify array") }
        return values
    }

    /// `"…"` with backslash, quote and control characters escaped.
    static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// 1-based line number of a byte offset, for error messages.
    static func lineNumber(of offset: Int, in bytes: [UInt8]) -> Int {
        bytes[..<min(offset, bytes.count)].reduce(1) { $1 == ASCII.lf ? $0 + 1 : $0 }
    }

    /// `"\r\n"` when the file's first line break is CRLF, otherwise `"\n"`.
    static func lineBreak(in bytes: [UInt8]) -> [UInt8] {
        guard let lf = bytes.firstIndex(of: ASCII.lf) else { return [ASCII.lf] }
        return lf > 0 && bytes[lf - 1] == ASCII.cr ? [ASCII.cr, ASCII.lf] : [ASCII.lf]
    }

    /// Removes `start..<end` together with its line break. For a last line without a line break, the preceding
    /// line break is removed instead, so removing an appended line restores the file exactly.
    static func removingLine(from bytes: [UInt8], start: Int, end: Int) -> [UInt8] {
        var start = start
        var end = end
        if end < bytes.count {
            end += bytes[end] == ASCII.cr ? 2 : 1
        } else if start > 0, bytes[start - 1] == ASCII.lf {
            start -= 1
            if start > 0, bytes[start - 1] == ASCII.cr { start -= 1 }
        }
        return Array(bytes[..<start]) + Array(bytes[end...])
    }
}

enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let backslash = UInt8(ascii: "\\")
    static let hash = UInt8(ascii: "#")
    static let comma = UInt8(ascii: ",")
    static let dot = UInt8(ascii: ".")
    static let equals = UInt8(ascii: "=")
    static let lbracket = UInt8(ascii: "[")
    static let rbracket = UInt8(ascii: "]")
    static let lbrace = UInt8(ascii: "{")
    static let rbrace = UInt8(ascii: "}")
}

private struct Cursor {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { i >= bytes.count }

    func peek(_ offset: Int = 0) -> UInt8? {
        let j = i + offset
        return j >= 0 && j < bytes.count ? bytes[j] : nil
    }

    func error(_ reason: String) -> CodexConfigTOML.ScanError {
        CodexConfigTOML.ScanError(offset: min(i, bytes.count), reason: reason)
    }

    func isTripleQuote(_ delimiter: UInt8) -> Bool {
        peek() == delimiter && peek(1) == delimiter && peek(2) == delimiter
    }

    mutating func skipSpaces() {
        while let c = peek(), c == ASCII.space || c == ASCII.tab { i += 1 }
    }

    /// Skips a `#` comment up to (not including) the line break.
    mutating func skipComment() {
        guard peek() == ASCII.hash else { return }
        while let c = peek(), c != ASCII.lf, !(c == ASCII.cr && peek(1) == ASCII.lf) { i += 1 }
    }

    /// Spaces, comments and line breaks (inside arrays and inline tables).
    mutating func skipTrivia() {
        while true {
            skipSpaces()
            skipComment()
            if peek() == ASCII.lf {
                i += 1
            } else if peek() == ASCII.cr, peek(1) == ASCII.lf {
                i += 2
            } else {
                return
            }
        }
    }

    /// Requires end of file or a line break; consumes the line break and returns the offset where it started.
    mutating func consumeLineEnd() throws -> Int {
        let end = i
        if atEnd { return end }
        if peek() == ASCII.lf { i += 1; return end }
        if peek() == ASCII.cr, peek(1) == ASCII.lf { i += 2; return end }
        throw error("expected end of line")
    }

    /// Bare, quoted or dotted key, e.g. `notify`, `"notify"`, `a . 'b'`.
    mutating func parseKey() throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            switch peek() {
            case ASCII.quote? where !isTripleQuote(ASCII.quote):
                parts.append(try readBasicString())
            case ASCII.apostrophe? where !isTripleQuote(ASCII.apostrophe):
                parts.append(try readLiteralString())
            default:
                let start = i
                while let c = peek(), Self.isBareKeyByte(c) { i += 1 }
                guard i > start else { throw error("expected a key") }
                parts.append(String(decoding: bytes[start..<i], as: UTF8.self))
            }
            skipSpaces()
            guard peek() == ASCII.dot else { return parts }
            i += 1
        }
    }

    static func isBareKeyByte(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
    }

    /// Skips any TOML value: strings (all four kinds), arrays, inline tables, and scalars (numbers, booleans, dates).
    mutating func skipValue() throws {
        guard let c = peek() else { throw error("missing value") }
        switch c {
        case ASCII.quote:
            if isTripleQuote(ASCII.quote) { try skipMultiLineString(ASCII.quote, escapes: true) } else { _ = try readBasicString() }
        case ASCII.apostrophe:
            if isTripleQuote(ASCII.apostrophe) { try skipMultiLineString(ASCII.apostrophe, escapes: false) } else { _ = try readLiteralString() }
        case ASCII.lbracket:
            i += 1
            while true {
                skipTrivia()
                if peek() == ASCII.rbracket { i += 1; return }
                try skipValue()
                skipTrivia()
                if peek() == ASCII.comma { i += 1; continue }
                if peek() == ASCII.rbracket { i += 1; return }
                throw error("expected ',' or ']' in array")
            }
        case ASCII.lbrace:
            i += 1
            while true {
                skipTrivia()
                if peek() == ASCII.rbrace { i += 1; return }
                _ = try parseKey()
                skipSpaces()
                guard peek() == ASCII.equals else { throw error("expected '=' in inline table") }
                i += 1
                skipSpaces()
                try skipValue()
                skipTrivia()
                if peek() == ASCII.comma { i += 1; continue }
                if peek() == ASCII.rbrace { i += 1; return }
                throw error("expected ',' or '}' in inline table")
            }
        default:
            let start = i
            let stops: [UInt8] = [ASCII.lf, ASCII.cr, ASCII.hash, ASCII.comma, ASCII.rbracket, ASCII.rbrace]
            while let c = peek(), !stops.contains(c) { i += 1 }
            while i > start, bytes[i - 1] == ASCII.space || bytes[i - 1] == ASCII.tab { i -= 1 }
            guard i > start else { throw error("missing value") }
        }
    }

    mutating func skipMultiLineString(_ delimiter: UInt8, escapes: Bool) throws {
        i += 3
        while true {
            guard let c = peek() else { throw error("unterminated multi-line string") }
            if escapes, c == ASCII.backslash {
                i += 2
                continue
            }
            if isTripleQuote(delimiter) {
                i += 3
                // Up to two quotes may directly precede the closing delimiter (`"""a""""`).
                var extra = 0
                while extra < 2, peek() == delimiter { i += 1; extra += 1 }
                return
            }
            i += 1
        }
    }

    mutating func readLiteralString() throws -> String {
        i += 1
        let start = i
        while true {
            guard let c = peek(), c != ASCII.lf, c != ASCII.cr else { throw error("unterminated string") }
            if c == ASCII.apostrophe { break }
            i += 1
        }
        let value = try decode(Array(bytes[start..<i]))
        i += 1
        return value
    }

    mutating func readBasicString() throws -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard let c = peek(), c != ASCII.lf, c != ASCII.cr else { throw error("unterminated string") }
            i += 1
            switch c {
            case ASCII.quote:
                return try decode(out)
            case ASCII.backslash:
                try readEscape(into: &out)
            default:
                out.append(c)
            }
        }
    }

    private mutating func readEscape(into out: inout [UInt8]) throws {
        guard let e = peek() else { throw error("unterminated string") }
        i += 1
        switch e {
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "e"): out.append(0x1B)
        case ASCII.quote, ASCII.backslash: out.append(e)
        case UInt8(ascii: "x"): try appendScalar(hexDigits: 2, into: &out)
        case UInt8(ascii: "u"): try appendScalar(hexDigits: 4, into: &out)
        case UInt8(ascii: "U"): try appendScalar(hexDigits: 8, into: &out)
        default: throw error("invalid escape sequence")
        }
    }

    private mutating func appendScalar(hexDigits: Int, into out: inout [UInt8]) throws {
        guard i + hexDigits <= bytes.count,
              let value = UInt32(String(decoding: bytes[i..<(i + hexDigits)], as: UTF8.self), radix: 16),
              let scalar = Unicode.Scalar(value)
        else { throw error("invalid unicode escape") }
        i += hexDigits
        var string = ""
        string.unicodeScalars.append(scalar)
        out.append(contentsOf: string.utf8)
    }

    private func decode(_ utf8: [UInt8]) throws -> String {
        let string = String(decoding: utf8, as: UTF8.self)
        guard Array(string.utf8) == utf8 else { throw error("string is not valid UTF-8") }
        return string
    }
}
