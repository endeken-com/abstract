import Foundation

/// Which builds an installed Abstract updates to. Every build reads the same
/// appcast; the channel only decides whether its nightly entries count.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable, nightly

    /// The UserDefaults key the choice is stored under.
    public static let defaultsKey = "updates.channel"

    /// The stored choice; anything missing or unknown means stable.
    public init(stored: String?) {
        self = stored.flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    public var detail: String {
        switch self {
        case .stable: "Releases, once they're cut and tested."
        case .nightly: "A build of main every day. May be unstable."
        }
    }

    /// Sparkle channels to accept on top of the default one, which every build sees.
    public var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        }
    }
}

public enum UpdatePolicy {
    /// Dev builds carry version 0.0.0 (CI sets real versions from tags), and
    /// neither they, debug builds nor demo runs may replace themselves with a release.
    public static func shouldStart(version: String?, isDebug: Bool, isDemo: Bool) -> Bool {
        guard let version, !version.isEmpty, version != "0.0.0" else { return false }
        return !isDebug && !isDemo
    }
}
