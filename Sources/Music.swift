// PLAY's music macro language: notes A–G with sharps/flats and lengths, O/</>/L/T/P/N, and the
// MN/ML/MS articulation and MF/MB foreground/background modes. Settings carry over between PLAYs.

import Foundation

struct Note {
    var hz: Double        // 0 for a rest
    var sound: Double     // seconds the note sounds
    var gap: Double       // seconds of silence after it (articulation)
}

final class MusicState {
    var octave = 4
    var length = 4.0
    var tempo = 120.0
    var style = 7.0 / 8.0
    var background = false

    func reset() { octave = 4; length = 4; tempo = 120; style = 7.0 / 8.0; background = false }

    /// Note number n (1…84; octave 3 starts at middle C, so O3 A = 440 Hz).
    static func frequency(_ n: Int) -> Double { 440 * pow(2, Double(n - 46) / 12) }

    func parse(_ s: String) throws -> [Note] {
        let c = Array(s.uppercased())
        var i = 0
        var notes: [Note] = []

        func number() -> Int? {
            var v = "", j = i
            while j < c.count, c[j].isNumber { v.append(c[j]); j += 1 }
            guard !v.isEmpty else { return nil }
            i = j
            return Int(v)
        }
        func dots() -> Double {
            var mult = 1.0, add = 0.5
            while i < c.count, c[i] == "." { mult += add; add /= 2; i += 1 }
            return mult
        }
        func add(hz: Double, len: Double, dotted: Double) {
            let total = (4 / len) * (60 / tempo) * dotted
            if hz == 0 { notes.append(Note(hz: 0, sound: 0, gap: total)); return }
            notes.append(Note(hz: hz, sound: total * style, gap: total * (1 - style)))
        }

        let semis: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        while i < c.count {
            let ch = c[i]
            i += 1
            switch ch {
            case " ", ";": continue
            case "A"..."G":
                var semi = semis[ch]!
                if i < c.count, c[i] == "#" || c[i] == "+" { semi += 1; i += 1 } else if i < c.count, c[i] == "-" { semi -= 1; i += 1 }
                let len = number().map(Double.init) ?? length
                guard len >= 1, len <= 64 else { throw BasicError.illegalFunctionCall("PLAY note length") }
                let n = octave * 12 + semi + 1
                add(hz: MusicState.frequency(n), len: len, dotted: dots())
            case "N":
                guard let n = number(), n >= 0, n <= 84 else { throw BasicError.illegalFunctionCall("PLAY N") }
                add(hz: n == 0 ? 0 : MusicState.frequency(n), len: length, dotted: dots())
            case "O":
                guard let n = number(), n >= 0, n <= 6 else { throw BasicError.illegalFunctionCall("PLAY O") }
                octave = n
            case "<": octave = max(0, octave - 1)
            case ">": octave = min(6, octave + 1)
            case "L":
                guard let n = number(), n >= 1, n <= 64 else { throw BasicError.illegalFunctionCall("PLAY L") }
                length = Double(n)
            case "T":
                guard let n = number(), n >= 32, n <= 255 else { throw BasicError.illegalFunctionCall("PLAY T") }
                tempo = Double(n)
            case "P", "R":
                guard let n = number(), n >= 1, n <= 64 else { throw BasicError.illegalFunctionCall("PLAY P") }
                add(hz: 0, len: Double(n), dotted: dots())
            case "M":
                guard i < c.count else { throw BasicError.illegalFunctionCall("PLAY M") }
                let m = c[i]; i += 1
                switch m {
                case "N": style = 7.0 / 8.0
                case "L": style = 1
                case "S": style = 3.0 / 4.0
                case "F": background = false
                case "B": background = true
                default: throw BasicError.illegalFunctionCall("PLAY M\(m)")
                }
            default:
                throw BasicError.illegalFunctionCall("PLAY can't use '\(ch)'")
            }
        }
        return notes
    }
}
