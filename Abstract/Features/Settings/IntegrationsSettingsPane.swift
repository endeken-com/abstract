import SwiftUI
import AbstractCore

/// Revund's settings. GitHub (ABS-139) and issue trackers such as Linear
/// (ABS-141) are plugins now, each with its own page under Settings →
/// Plugins.
struct IntegrationsSettingsPane: View {
    var body: some View {
        Form {
            RevundSettingsSection()
        }
        .settingsPane()
    }
}
