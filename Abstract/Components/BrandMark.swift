import SwiftUI

/// Abstract's mark: the rounded, hand-drawn loop. Drawn from the logo's own
/// SVG path, so it stays crisp at any size and takes the current colour.
nonisolated struct AbstractMark: Shape {
    func path(in rect: CGRect) -> Path { SVGPath.fit(Self.source, in: rect) }

    static let source = SVGPath.parse("M93.67,50c-0.4,9-8.84,14.39-15.12,19.54-6.08,5-10.27,11.3-15.62,17-7.09,7.51-15.66,9.2-23.62,1.85-5.69-5.25-9.59-12.08-15.48-17.16S9.3,61.23,7.17,53.25C4.73,44.13,13,37.56,19.28,32.53S30.14,22,35.27,16C41.18,9,49.1,3.23,58,9.13,65.36,14,69.51,22.59,76.1,28.4,82.85,34.34,93.22,39.95,93.67,50c0.09,1.92,3.09,1.93,3,0-0.43-9.53-8.15-15.31-15-20.84C74.09,23,69.22,14.46,61.78,8.27,55.37,2.93,47.38,2,40.4,6.88,32.57,12.37,28,21.39,20.73,27.51,14.33,32.87,5.7,38.28,4,47.13c-1.74,9.11,5.18,15.93,11.6,21.2,3.6,3,7.34,5.74,10.47,9.22s6,7.57,9.28,11.07C41,94.63,48.71,98.71,56.86,95c9.45-4.35,14.2-15.05,21.84-21.65C86.18,66.85,96.18,61,96.67,50,96.76,48.07,93.76,48.07,93.67,50Z")
}

/// The ABSTRACT wordmark from the logo.
nonisolated struct AbstractWordmark: Shape {
    func path(in rect: CGRect) -> Path { SVGPath.fit(Self.source, in: rect) }

    static let source = SVGPath.parse("M5.34 6.14 c0 0.08 0.23666 0.84334 0.71 2.29 s0.99 3.03 1.55 4.75 s1.31334 3.99334 2.26 6.82 l0.86 0 l-5.3 -15.76 l-0.16 0 l-5.26 15.76 l0.82 0 z M4.98 15.52 l-0.72 0 l1.2 4.48 l0.72 0 z M13 10.94 l0.000039 9.06 l3.84 0 c1.14666 0 2.05332 -0.40666 2.71998 -1.22 s1 -1.86668 1 -3.16002 c0 -0.34666 -0.04334 -0.74332 -0.13 -1.18998 s-0.23332 -0.88 -0.43998 -1.3 s-0.48666 -0.8 -0.84 -1.14 s-0.81 -0.57666 -1.37 -0.71 c0.56 -0.34666 0.96666 -0.81 1.22 -1.39 s0.38 -1.19 0.38 -1.83 c0 -1.22666 -0.34 -2.17 -1.02 -2.83 s-1.60666 -0.99 -2.78 -0.99 l-2.58 0 l0 6.22 l0.7 0 l-0.02 -5.4 l1.96 0 c1.10666 0 1.88666 0.29 2.34 0.87 s0.68 1.29 0.68 2.13 c0 0.90666 -0.20666 1.61 -0.62 2.11 s-0.98 0.75 -1.7 0.75 l-2.62 0 l0.44 0.88 l2.68 0 c0.54666 0 1.01332 0.12334 1.39998 0.37 s0.70332 0.55666 0.94998 0.93 s0.43 0.79334 0.55 1.26 s0.18 0.92 0.18 1.36 c0 0.42666 -0.06 0.84666 -0.18 1.26 s-0.3 0.78334 -0.54 1.11 s-0.55334 0.59 -0.94 0.79 s-0.84666 0.3 -1.38 0.3 l-3.2 0 l0.02 -8.24 l-0.7 0 z M25.24 11.02 l1.78004 1.66 c0.56 0.52 1 1.07666 1.32 1.67 s0.48 1.19 0.48 1.79 l0 0.26 c0.01334 0.42666 -0.04 0.80666 -0.16 1.14 l0.74 0 c0.10666 -0.36 0.15332 -0.73334 0.13998 -1.12 l0 -0.28 c0 -0.72 -0.18334 -1.40666 -0.55 -2.06 s-0.87666 -1.29334 -1.53 -1.92 l-1.72 -1.62 c-0.54666 -0.52 -0.99666 -1.00666 -1.35 -1.46 s-0.53 -1.02 -0.53 -1.7 l0 -0.12 c0 -0.70666 0.19666 -1.27666 0.59 -1.71 s0.94334 -0.65 1.65 -0.65 c0.50666 0 0.92 0.07666 1.24 0.23 s0.64666 0.38334 0.98 0.69 l0.46 -0.52 c-0.37334 -0.34666 -0.75668 -0.60666 -1.15002 -0.78 s-0.90334 -0.26 -1.53 -0.26 c-0.81334 0 -1.50334 0.26334 -2.07 0.79 s-0.85 1.25666 -0.85 2.19 l0 0.16 c0 0.76 0.19 1.41 0.57 1.95 s0.87666 1.09666 1.49 1.67 z M29.12004 18.3 l-0.82002 0 c-0.46666 0.68 -1.21332 1.02666 -2.23998 1.04 c-0.34666 0 -0.66 -0.04 -0.94 -0.12 l0 0.7 c0.28 0.05334 0.59334 0.08 0.94 0.08 c0.72 0 1.34 -0.14666 1.86 -0.44 s0.92 -0.71334 1.2 -1.26 z M38 4.5 l-0.00002 -0.26 l-5.86 0 l0 0.64 l3.38 0 l0 15.12 l0.7 0 l0 -15.12 l1.8 0 c-0.02666 -0.21334 -0.03332 -0.34 -0.01998 -0.38 z M38.51998 4.24 l0 0.64 l1.1 0 l0 -0.64 l-1.1 0 z M46.62 15.22 c0.85334 -0.48 1.50668 -1.15668 1.96002 -2.03002 s0.68 -1.86334 0.68 -2.97 l0 -0.28 c0 -1.64 -0.49 -3 -1.47 -4.08 s-2.37666 -1.62 -4.19 -1.62 l-1.38 0 l0 6.34 c0.22666 0.01334 0.45332 0.02 0.67998 0.02 l0 -5.72 l0.66 0 c1.64 0 2.88 0.47666 3.72 1.43 s1.26 2.17668 1.26 3.67002 l0 0.22 c0 1.48 -0.42 2.69334 -1.26 3.64 s-2.08 1.42 -3.72 1.42 l-0.66 0 l0 0 l-0.68 0 l0 0.64 c0.4 0.01334 0.66666 0.02 0.8 0.02 l0.58 0 c0.92 0 1.72666 -0.14 2.42 -0.42 l2.48 4.5 l0.8 0 z M57.24 6.14 c0 0.08 0.23666 0.84334 0.71 2.29 s0.99 3.03 1.55 4.75 s1.31334 3.99334 2.26 6.82 l0.86 0 l-5.3 -15.76 l-0.16 0 l-5.26 15.76 l0.82 0 z M56.88 15.52 l-0.72 0 l1.2 4.48 l0.72 0 z M72.16 19.96 l0.039941 -0.63998 c-1.96 -0.13334 -3.52 -0.94668 -4.68 -2.44002 c-1.10666 -1.38666 -1.66 -3.06 -1.66 -5.02 c0 -1.02666 0.16666 -1.91666 0.5 -2.67 s0.83334 -1.48334 1.5 -2.19 c1.33334 -1.4 3 -2.1 5 -2.1 c1.21334 0 2.30668 0.26 3.28002 0.78 s1.76668 1.24666 2.38002 2.18 l0.48 -0.38 c-0.66666 -1.01334 -1.53332 -1.80668 -2.59998 -2.38002 c-1.01334 -0.54666 -2.16 -0.81332 -3.44 -0.79998 c-1.08 0 -2.09334 0.18334 -3.04 0.55 s-1.78 0.93 -2.5 1.69 c-0.72 0.77334 -1.26334 1.57334 -1.63 2.4 s-0.55 1.8 -0.55 2.92 c0.01334 2.12 0.62 3.93334 1.82 5.44 c1.28 1.61334 2.98 2.5 5.1 2.66 z M73.37994 19.98002 c1.09334 -0.06666 2.09334 -0.32664 3 -0.77998 c1.04 -0.53334 1.91334 -1.28668 2.62 -2.26002 l-0.46 -0.4 c-0.64 0.88 -1.44666 1.57334 -2.42 2.08 c-0.84 0.42666 -1.76 0.66666 -2.76 0.72 z M87.46 4.5 l-0.00002 -0.26 l-5.86 0 l0 0.64 l3.38 0 l0 15.12 l0.7 0 l0 -15.12 l1.8 0 c-0.02666 -0.21334 -0.03332 -0.34 -0.01998 -0.38 z M87.97998 4.24 l0 0.64 l1.1 0 l0 -0.64 l-1.1 0 z")
}

/// Just enough of SVG path syntax for the logo: M L H V C S Q T Z, absolute
/// and relative, with implicit repeats.
nonisolated enum SVGPath {
    static func fit(_ source: Path, in rect: CGRect) -> Path {
        let bounds = source.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return source }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let dx = rect.midX - bounds.midX * scale, dy = rect.midY - bounds.midY * scale
        return source.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }

    static func parse(_ d: String) -> Path {
        var tokens = Tokens(d)
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: Character = "M"
        while let next = tokens.nextCommandOrRepeat(command) {
            command = next
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased() {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p); current = p; start = p; lastControl = nil
                command = relative ? "l" : "L" // further pairs are lines
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "Q":
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case "T":
                let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Tokens {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }

        /// The next command letter, or `last` again when numbers follow
        /// without one (SVG's implicit repeat). Z never repeats.
        mutating func nextCommandOrRepeat(_ last: Character) -> Character? {
            skipSeparators()
            guard i < chars.count else { return nil }
            if chars[i].isLetter, chars[i] != "e", chars[i] != "E" {
                defer { i += 1 }
                return chars[i]
            }
            return last == "Z" || last == "z" ? nil : last
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { i += 1 }
                else if c == ".", !dot { dot = true; i += 1 }
                else if c == "e" || c == "E" {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            guard i > begin, let value = Double(String(chars[begin..<i])) else { return nil }
            return CGFloat(value)
        }
    }
}
