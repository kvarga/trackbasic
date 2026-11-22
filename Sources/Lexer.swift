// Tokens for one source line.

import Foundation

enum BasicError: Error {
    case syntax(String)
    case illegalFunctionCall(String)
    case typeMismatch
    case subscriptOutOfRange
    case divisionByZero
    case overflow
    case outOfData
    case returnWithoutGosub
    case labelNotDefined(String)
    case runtime(String)

    var message: String {
        switch self {
        case .syntax(let s): return "Syntax error: \(s)"
        case .illegalFunctionCall(let s): return "Illegal function call" + (s.isEmpty ? "" : ": \(s)")
        case .typeMismatch: return "Type mismatch"
        case .subscriptOutOfRange: return "Subscript out of range"
        case .divisionByZero: return "Division by zero"
        case .overflow: return "Overflow"
        case .outOfData: return "Out of DATA"
        case .returnWithoutGosub: return "RETURN without GOSUB"
        case .labelNotDefined(let s): return "Label not defined: \(s)"
        case .runtime(let s): return s
        }
    }
}

struct Token: Equatable {
    enum Kind: Equatable { case number, string, ident, keyword, op, eol }
    var kind: Kind
    var text: String      // keywords and identifiers upper-cased; strings without quotes
    var number: Double = 0
    var column = 0        // where it starts in the line, for upper-casing keywords in the editor
    var length = 0
}

let keywords: Set<String> = [
    "PRINT", "INPUT", "LINE", "LET", "IF", "THEN", "ELSE", "ELSEIF", "END", "FOR", "TO", "STEP", "NEXT", "WHILE", "WEND",
    "DO", "LOOP", "UNTIL", "GOTO", "GOSUB", "RETURN", "DIM", "REDIM", "SHARED", "AS", "CLS", "COLOR", "LOCATE", "SLEEP",
    "BEEP", "SOUND", "PLAY", "RANDOMIZE", "REM", "SELECT", "CASE", "IS", "DATA", "READ", "RESTORE", "SUB", "FUNCTION",
    "CALL", "EXIT", "CONST", "AND", "OR", "NOT", "XOR", "EQV", "IMP", "MOD", "SCREEN", "PSET", "PRESET", "CIRCLE", "PAINT",
    "SWAP", "STOP", "SYSTEM", "DECLARE", "STATIC", "INTEGER", "LONG", "SINGLE", "DOUBLE", "STRING", "ON", "USING",
    "WIDTH", "KEY", "VIEW", "DEFINT", "DEFSNG", "DEFDBL", "DEFLNG", "DEFSTR", "OFF", "ERASE", "OPTION", "BASE",
]

func tokenize(_ line: String) throws -> [Token] {
    var out: [Token] = []
    let chars = Array(line)
    var i = 0
    func isIdentStart(_ c: Character) -> Bool { c.isLetter && c.isASCII }
    func isIdentChar(_ c: Character) -> Bool { (c.isLetter || c.isNumber) && c.isASCII || c == "." || c == "_" }
    while i < chars.count {
        let c = chars[i]
        let start = i
        if c == " " || c == "\t" { i += 1; continue }
        if c == "'" { break }
        if c == "\"" {
            i += 1
            var s = ""
            while i < chars.count && chars[i] != "\"" { s.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 }
            out.append(Token(kind: .string, text: s, column: start, length: i - start))
            continue
        }
        if c.isNumber && c.isASCII || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
            var s = ""
            while i < chars.count && (chars[i].isNumber && chars[i].isASCII || chars[i] == ".") { s.append(chars[i]); i += 1 }
            if i < chars.count, chars[i] == "E" || chars[i] == "e" || chars[i] == "D" || chars[i] == "d" {
                var j = i + 1
                var exp = "e"
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { exp.append(chars[j]); j += 1 }
                if j < chars.count, chars[j].isNumber {
                    while j < chars.count && chars[j].isNumber { exp.append(chars[j]); j += 1 }
                    s += exp; i = j
                }
            }
            if i < chars.count, "%&!#".contains(chars[i]) { i += 1 }
            out.append(Token(kind: .number, text: s, number: Double(s) ?? 0, column: start, length: i - start))
            continue
        }
        if c == "&" && i + 1 < chars.count && (chars[i + 1] == "H" || chars[i + 1] == "h" || chars[i + 1] == "O" || chars[i + 1] == "o") {
            let radix = chars[i + 1].uppercased() == "H" ? 16 : 8
            i += 2
            var s = ""
            while i < chars.count, chars[i].isHexDigit { s.append(chars[i]); i += 1 }
            if i < chars.count, chars[i] == "&" { i += 1 }
            var v = Double(Int(s, radix: radix) ?? 0)
            if radix == 16 && s.count <= 4 && v >= 32768 { v -= 65536 }
            out.append(Token(kind: .number, text: s, number: v, column: start, length: i - start))
            continue
        }
        if isIdentStart(c) {
            var s = ""
            while i < chars.count && isIdentChar(chars[i]) { s.append(chars[i]); i += 1 }
            if i < chars.count, "$%&!#".contains(chars[i]) { s.append(chars[i]); i += 1 }
            let up = s.uppercased()
            if up == "REM" { out.append(Token(kind: .keyword, text: up, column: start, length: 3)); break }
            out.append(Token(kind: keywords.contains(up) ? .keyword : .ident, text: up, column: start, length: i - start))
            continue
        }
        if c == "<" || c == ">" {
            if i + 1 < chars.count, chars[i + 1] == "=" || (c == "<" && chars[i + 1] == ">") {
                out.append(Token(kind: .op, text: String([c, chars[i + 1]]), column: start, length: 2)); i += 2; continue
            }
            if c == ">" && i + 1 < chars.count && chars[i + 1] == "<" {
                out.append(Token(kind: .op, text: "<>", column: start, length: 2)); i += 2; continue
            }
        }
        if c == "=" && i + 1 < chars.count && (chars[i + 1] == "<" || chars[i + 1] == ">") {
            out.append(Token(kind: .op, text: String([chars[i + 1], "="]), column: start, length: 2)); i += 2; continue
        }
        if "+-*/\\^=<>(),;:#".contains(c) {
            out.append(Token(kind: .op, text: String(c), column: start, length: 1)); i += 1; continue
        }
        throw BasicError.syntax("unexpected character '\(c)'")
    }
    out.append(Token(kind: .eol, text: "", column: chars.count))
    return out
}

/// Upper-cases keywords (outside strings and comments), the way the QBasic editor tidies a line.
func tidyLine(_ line: String) -> String {
    guard let toks = try? tokenize(line) else { return line }
    var chars = Array(line)
    for t in toks where t.kind == .keyword || (t.kind == .ident && builtinNames.contains(t.text)) {
        for k in t.column..<min(chars.count, t.column + t.length) {
            chars[k] = Character(chars[k].uppercased())
        }
    }
    return String(chars)
}
