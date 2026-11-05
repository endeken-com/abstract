import SwiftUI

/// The supplied geometric symbol, kept as two contours for the loading trace.
nonisolated struct AbstractMark: Shape {
    func path(in rect: CGRect) -> Path { SVGPath.fit(Self.source, in: rect) }

    static let source: Path = {
        var path = Path()
        for contour in contours { path.addPath(SVGPath.parse(contour)) }
        return path
    }()

    static let contours = [
        "M6.649 44.737 0 33.562 6.649 22.368H19.933L13.289 33.562 19.933 44.737H6.649Z",
        "M26.577 11.184 19.933 0 13.289 11.184 19.669 21.925 19.933 22.368 26.577 33.562 33.222 44.737 39.862 33.562 33.222 22.368 26.577 11.184Z",
    ]
}

/// The lettering in the supplied Abstract lockup.
nonisolated struct AbstractWordmark: Shape {
    func path(in rect: CGRect) -> Path { SVGPath.fit(Self.source, in: rect) }

    static let source = SVGPath.parse("M9.26 15.1 l-1.52 -5.16 l-1.46 5.16 l2.98 0 z M4.84 20 l-4.62 0 l5.16 -14.4 l4.8 0 l5.16 14.4 l-4.7 0 l-0.56 -1.9 l-4.7 0 z M20.68 5.6 l0 4.98 c0.82 -0.96 1.78 -1.36 3.02 -1.36 c2.68 0 4.56 2.32 4.56 5.48 c0 3.1 -1.32 5.6 -4.74 5.6 c-1.74 0 -2.7 -0.78 -3.22 -1.78 l-0.04 0 l0 1.48 l-3.74 0 l0 -14.4 l4.16 0 z M22.34 17.3 c1.36 0 1.76 -1.32 1.76 -2.46 c0 -1.12 -0.42 -2.4 -1.76 -2.4 c-1.26 0 -1.76 1.24 -1.76 2.32 c0 1.12 0.4 2.54 1.76 2.54 z M29.56 16.74 l3.96 0 c0 0.42 0.16 0.74 0.44 0.96 c0.26 0.2 0.62 0.32 1.02 0.32 c0.64 0 1.32 -0.2 1.32 -0.94 c0 -1.68 -6.42 -0.34 -6.42 -4.4 c0 -2.68 2.78 -3.46 4.96 -3.46 c2.28 0 4.96 0.52 5.2 3.3 l-3.78 0 c-0.04 -0.34 -0.18 -0.58 -0.4 -0.76 s-0.52 -0.26 -0.84 -0.26 c-0.72 0 -1.18 0.22 -1.18 0.74 c0 1.46 6.62 0.48 6.62 4.4 c0 2.18 -1.8 3.66 -5.64 3.66 c-2.4 0 -5.04 -0.74 -5.26 -3.56 z M49 17.02 l0 2.98 c-5.46 0.3 -6.12 -0.08 -6.12 -3.7 l0 -4.38 l-1.48 0 l0 -2.4 l1.54 0 l0 -3.26 l4.1 0 l0 3.26 l2 0 l0 2.4 l-2 0 l0 3.8 c0 0.96 0.14 1.3 1.3 1.3 l0.66 0 z M51.04 20 l0 -10.48 l3.78 0 l0 2.12 l0.04 0 c0.58 -1.64 1.6 -2.42 3.22 -2.42 c0.18 0 0.36 0.04 0.54 0.06 l0 4.16 c-0.28 -0.04 -0.58 -0.12 -0.86 -0.12 c-1.7 0 -2.56 0.8 -2.56 3.06 l0 3.62 l-4.16 0 z M71.56 20 l-4.3 0 l-0.2 -1.12 c-1.18 1.1 -2.38 1.42 -3.94 1.42 c-1.98 0 -3.74 -0.98 -3.74 -3.16 c0 -4.76 7.46 -2.6 7.46 -4.56 c0 -0.76 -0.92 -0.86 -1.36 -0.86 c-0.58 0 -1.36 0.12 -1.46 1.02 l-4 0 c0 -2.22 1.58 -3.52 5.72 -3.52 c4.96 0 5.26 1.84 5.26 4.34 l0 4.9 c0 0.6 0.02 0.9 0.56 1.34 l0 0.2 z M65 17.94 c1.46 0 1.94 -1.14 1.84 -2.58 c-1.36 0.66 -3.16 0.34 -3.16 1.7 c0 0.52 0.5 0.88 1.32 0.88 z M84.58 13.52 l-4.22 0 c-0.02 -0.46 -0.18 -0.82 -0.44 -1.08 c-0.26 -0.28 -0.62 -0.42 -1.08 -0.42 c-1.56 0 -1.82 1.62 -1.82 2.86 c0 1.58 0.6 2.62 1.82 2.62 c1.08 0 1.5 -0.74 1.62 -1.56 l4.2 0 c-0.18 1.58 -0.9 2.68 -1.96 3.38 c-1.04 0.68 -2.4 0.98 -3.86 0.98 c-3.38 0 -5.98 -1.9 -5.98 -5.44 c0 -3.58 2.52 -5.64 5.98 -5.64 c2.8 0 5.44 1.2 5.74 4.3 z M93.44 17.02 l0 2.98 c-5.46 0.3 -6.12 -0.08 -6.12 -3.7 l0 -4.38 l-1.48 0 l0 -2.4 l1.54 0 l0 -3.26 l4.1 0 l0 3.26 l2 0 l0 2.4 l-2 0 l0 3.8 c0 0.96 0.14 1.3 1.3 1.3 l0.66 0 z")
}

/// The full lockup uses the spacing and proportions of the supplied SVG.
struct AbstractLogo: View {
    var height: CGFloat = 44

    var body: some View {
        HStack(spacing: height * 0.199) {
            AbstractMark().fill(Color.btText)
                .frame(width: height * 0.871, height: height)
            AbstractWordmark().fill(Color.btText)
                .frame(width: height * 2.793, height: height)
        }
        .frame(width: height * 3.863, height: height)
        .accessibilityLabel("Abstract")
    }
}

/// A restrained outline draw for indeterminate progress throughout the app.
struct BrandProgressViewStyle: ProgressViewStyle {
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        BrandLoadingIndicator(size: controlSize == .mini ? 13 : controlSize == .small ? 17 : 22,
                              progress: configuration.fractionCompleted)
            .accessibilityLabel("Loading")
    }
}

private struct BrandLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    let size: CGFloat
    let progress: Double?

    var body: some View {
        ZStack {
            AbstractMark().stroke(Color.btText.opacity(0.22), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            AbstractMark()
                .trim(from: 0, to: progress ?? (reduceMotion ? 1 : drawn ? 1 : 0))
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size * 0.89, height: size)
        .onAppear { animateIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in animateIfNeeded() }
    }

    private func animateIfNeeded() {
        drawn = reduceMotion
        guard !reduceMotion, progress == nil else { return }
        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) { drawn = true }
    }
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
