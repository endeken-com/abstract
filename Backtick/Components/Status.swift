import SwiftUI
import BacktickCore

extension SessionStatus {
    var label: String {
        switch self {
        case .created: "Ready"
        case .provisioning: "Setting up"
        case .running: "Working"
        case .waitingInput: "Needs you"
        case .idle: "Your turn"
        case .finished: "Done"
        case .errored: "Error"
        }
    }

    var tint: Color {
        switch self {
        case .running, .provisioning: .accentColor
        case .waitingInput: .btAttention
        case .idle, .finished: .btAdded
        case .errored: .btRemoved
        case .created: .btTextTertiary
        }
    }
}

/// Status as a small solid dot. A working agent's dot breathes gently; nothing
/// glows or radiates. Always shown next to a word, never on its own.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 7
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: size, height: size)
            .opacity(status == .running && dim ? 0.35 : 1)
            .onAppear { breathe(status) }
            .onChange(of: status) { _, new in breathe(new) }
            .accessibilityHidden(true)
    }

    private func breathe(_ s: SessionStatus) {
        dim = false
        guard s == .running else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// Dot plus word, as plain text. No capsule, so it sits cleanly anywhere,
/// including next to native controls.
struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 6)
            Text(status.label)
        }
        .font(.btCaptionMedium)
        .foregroundStyle(status == .waitingInput || status == .errored ? status.tint : Color.btTextSecondary)
    }
}
