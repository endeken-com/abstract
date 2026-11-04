import Foundation
@testable import AbstractCore

/// Graphite, Paper and Ink as the app ships them: bundled theme plugins
/// (ABS-185), read from the repository.
enum BundledThemes {
    static var pluginsFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Abstract/Resources/Plugins")
    }

    static var folders: [URL] {
        ["graphite", "paper", "ink"].map { pluginsFolder.appendingPathComponent("theme-\($0).abstractplugin") }
    }

    static let catalog = ThemeCatalog(listed: ThemeCatalog.themes(inFolders: folders))
    static var all: [Theme] { catalog.listed }
}

extension Theme {
    static var graphite: Theme { BundledThemes.catalog.theme(ThemeCatalog.graphiteId) }
    static var paper: Theme { BundledThemes.catalog.theme(ThemeCatalog.paperId) }
    static var ink: Theme { BundledThemes.catalog.theme(ThemeCatalog.inkId) }
}
