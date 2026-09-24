import Foundation
import Observation
import Sparkle
import AbstractCore

/// Keeps Abstract up to date through Sparkle, from the appcast CI publishes to
/// GitHub Pages. Every build reads the same feed; the channel only decides
/// whether its nightly entries count, so switching back to Stable waits for
/// the next stable release (Sparkle never downgrades).
@Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    /// False in dev builds (0.0.0), debug builds and demo runs, which never update themselves.
    let isEnabled: Bool
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    var automaticallyChecksForUpdates: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    var channel: UpdateChannel {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.defaultsKey) }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        isEnabled = UpdatePolicy.shouldStart(version: version, isDebug: isDebug, isDemo: DemoBootstrap.current != nil)
        channel = UpdateChannel(stored: UserDefaults.standard.string(forKey: UpdateChannel.defaultsKey))
        automaticallyChecksForUpdates = false
        automaticallyDownloadsUpdates = false
        super.init()
        guard isEnabled else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastUpdateCheckDate = updater.lastUpdateCheckDate }
            },
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.sparkleChannels
    }
}
