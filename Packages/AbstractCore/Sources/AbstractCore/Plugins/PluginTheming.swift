import Foundation

/// How a plugin's page is coloured (ABS-134). The palette comes from the
/// theme picked in Abstract, never from the Mac's appearance, and reaches
/// the page before any of its own CSS: a plugin's first frame is already in
/// the theme, whichever plugin contributed it (ABS-185).
public struct PluginAppearance: Equatable, Sendable {
    public var theme: Theme
    /// A light theme under Match System with "Increase contrast" on.
    public var strongerBorders: Bool

    public init(theme: Theme, strongerBorders: Bool = false) {
        self.theme = theme
        self.strongerBorders = strongerBorders
    }

    /// The appearance for the theme picked in Settings. The Mac's own
    /// appearance only matters under Match System.
    public static func resolve(choice: ThemeChoice, systemDark: Bool, increasedContrast: Bool,
                               catalog: ThemeCatalog, picks: ThemePicks = .standard) -> PluginAppearance {
        let theme = choice.resolved(systemDark: systemDark, increasedContrast: increasedContrast, catalog: catalog, picks: picks)
        return PluginAppearance(theme: theme,
                                strongerBorders: choice.strongerBorders(dark: theme.isDark, increasedContrast: increasedContrast))
    }

    public var isDark: Bool { theme.isDark }

    /// The page's CSS `color-scheme`, so form controls and scrollbars match.
    public var colorScheme: String { isDark ? "dark" : "light" }

    /// Every palette colour, as `--abstract-<role>` takes it.
    public var tokens: [String: String] {
        Dictionary(uniqueKeysWithValues: PaletteRole.allCases.map {
            ($0.rawValue, PluginContext.css($0.swatch(in: theme, strongerBorders: strongerBorders)))
        })
    }

    public var canvas: Swatch { PaletteRole.canvas.swatch(in: theme) }

    /// What a page is told about its colours: in the `context` message, and
    /// at document start. `theme` is the plugin's own id for it
    /// (`graphite`, `paper`, `ink`, or a third-party theme's).
    public func jsonValue() -> [String: JSONValue] {
        [
            "theme": .string(theme.shortId),
            "colorScheme": .string(colorScheme),
            "tokens": .object(tokens.mapValues(JSONValue.string)),
            "fontFamily": .string(PluginTheming.fontFamily),
        ]
    }
}

public enum PluginTheming {
    public static let fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"

    /// Applies a `context` payload's colours to the page: every token as a
    /// `--abstract-*` variable, `color-scheme`, the canvas behind the page,
    /// and `data-abstract-theme` and `data-abstract-appearance` on the root
    /// for CSS that needs the name or the side.
    /// CSSOM writes, which the plugins' CSP allows.
    public static let applySource = """
    function (payload) {
      const root = document.documentElement;
      if (!root || !payload) return;
      const style = root.style;
      const tokens = payload.tokens || {};
      for (const name of Object.keys(tokens)) style.setProperty("--abstract-" + name, tokens[name]);
      if (payload.fontFamily) style.setProperty("--abstract-font", payload.fontFamily);
      if (payload.colorScheme) style.setProperty("color-scheme", payload.colorScheme);
      if (tokens.canvas) style.setProperty("background-color", tokens.canvas);
      if (payload.theme) root.setAttribute("data-abstract-theme", payload.theme);
      if (payload.colorScheme) root.setAttribute("data-abstract-appearance", payload.colorScheme);
    }
    """

    /// The page's colours, set before its own CSS loads: the first frame is
    /// never a system white.
    public static func documentStartScript(_ appearance: PluginAppearance) -> String {
        "(\(applySource))(\(JSONValue.object(appearance.jsonValue()).compact()));"
    }
}

/// The shared design kit (ABS-134), served to every plugin from the host's
/// own scheme: `<link rel="stylesheet" href="/_abstract/abstract-ui.css">`.
/// The path is reserved, so a package can't stand in for the kit.
public enum PluginKit {
    public static let prefix = "_abstract/"
    public static let files = ["abstract-ui.css", "abstract-ui.js"]

    /// Whether a request path is the kit's to answer, never the package's.
    public static func isKitPath(_ path: String) -> Bool { path.hasPrefix(prefix) }

    /// The kit file a request path names; nil for anything else, kit path
    /// or not.
    public static func file(forRequestPath path: String) -> String? {
        guard isKitPath(path) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        return files.contains(name) ? name : nil
    }
}
