import SwiftUI
import BacktickCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 268, max: 380)
        } detail: {
            DetailView()
                .frame(minWidth: 560, minHeight: 480)
                .background(Color.btCanvas)
        }
        .overlay {
            if model.isPaletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.snappy(duration: 0.18), value: model.isPaletteOpen)
        .sheet(isPresented: Binding(get: { model.newChatProjectId != nil }, set: { if !$0 { model.newChatProjectId = nil } })) {
            NewChatSheet(initialProjectId: model.newChatProjectId ?? nil)
        }
        .sheet(isPresented: $model.isAddingProject) { AddProjectSheet() }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.destination {
        case .home:
            HomeView()
        case .session(let id):
            if model.session(id) != nil {
                ChatView(sessionId: id).id(id)
            } else {
                EmptyStateView(symbol: "bubble.left.and.exclamationmark.bubble.right", title: "This chat no longer exists")
            }
        case .automations:
            AutomationsView()
        case .worktrees:
            WorktreesView()
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: Space.sm) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Color.btRemoved : Color.btAdded)
                    Text(toast.message).font(.btBody).foregroundStyle(Color.btText).lineLimit(2)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 10)
                .btRaised(radius: 12)
                .padding(.bottom, Space.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.toast)
    }
}
