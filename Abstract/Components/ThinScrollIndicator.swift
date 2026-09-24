import SwiftUI

extension View {
    /// A hairline scroll thumb instead of the system scroller: it shows
    /// while scrolling or when the pointer rests near the edge, then fades.
    func btThinScrollIndicator(topInset: CGFloat = 0) -> some View { modifier(ThinScrollIndicator(topInset: topInset)) }
}

private struct ThinScrollIndicator: ViewModifier {
    /// Room above the thumb's track, e.g. a title band the content runs under.
    let topInset: CGFloat
    /// Where the scroll stands, read only by the thumb: scrolling redraws the
    /// thumb, never the content it sits over.
    @State private var scroll = ScrollState()

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollState.Metrics.self) { g in
                ScrollState.Metrics(offset: g.contentOffset.y + g.contentInsets.top, content: g.contentSize.height, container: g.containerSize.height)
            } action: { old, new in
                scroll.metrics = new
                if abs(old.offset - new.offset) > 0.5 { scroll.flash() }
            }
            .overlay(alignment: .topTrailing) { Thumb(scroll: scroll, topInset: topInset) }
    }
}

@Observable
private final class ScrollState {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
    }

    var metrics = Metrics()
    var scrolling = false
    @ObservationIgnored private var fade: Task<Void, Never>?

    func flash() {
        if !scrolling { scrolling = true }
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { self?.scrolling = false }
        }
    }
}

private struct Thumb: View {
    let scroll: ScrollState
    let topInset: CGFloat
    @State private var nearEdge = false

    var body: some View {
        let m = scroll.metrics
        if m.content > m.container + 1, m.container > 0 {
            let track = m.container - topInset
            let height = max(28, track * m.container / m.content)
            let travel = track - height
            let progress = min(max(m.offset / (m.content - m.container), 0), 1)
            ZStack(alignment: .top) {
                // The pointer near the edge wakes the thumb without scrolling.
                Color.clear.frame(width: 14).contentShape(Rectangle())
                    .onHover { nearEdge = $0 }
                Capsule()
                    .fill(Color.btTextTertiary.opacity(nearEdge ? 0.7 : 0.45))
                    .frame(width: nearEdge ? 4 : 3, height: height)
                    .offset(y: topInset + travel * progress)
                    .padding(.trailing, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(scroll.scrolling || nearEdge ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: scroll.scrolling)
            .animation(.easeOut(duration: 0.15), value: nearEdge)
        }
    }
}
