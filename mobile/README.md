# Abstract Mobile

React Native and Expo app for iOS and Android. It connects to the Mac app's existing encrypted remote protocol. Agents, git worktrees, files, and automation schedules remain on the Mac.

## Develop

Requires Node 22 and an iOS or Android development build. Native TCP and Bonjour modules are not in Expo Go.

```sh
cd mobile
npm ci
npm run ios      # or npm run android
```

For a standalone iPhone build with the JavaScript bundle included, run `npm run ios:release -- --device`.

Run a Mac build with this remote protocol, then turn on Settings → Remote → Share this Mac. The mobile app discovers Macs advertising `_abstract._tcp` on the local network. Select one, compare the pairing code on both devices, and approve on the Mac. A direct `host:port` address works across a routed network or VPN; set a fixed remote port in the Mac app and arrange routing to that port. The Mac must be running and reachable. Pairing pins its Ed25519 identity; later connections reject a changed identity. Mobile keys live in the platform secure store.

## Store builds

Mobile releases are independent of Mac releases. iOS is built and signed in **Xcode Cloud**, with the resulting archive delivered to **App Store Connect**. The checked-in `ios/Abstract.xcworkspace` and `ios/ci_scripts/ci_post_clone.sh` install Node dependencies and CocoaPods on the Xcode Cloud runner. In Xcode, open `ios/Abstract.xcworkspace`, enable Xcode Cloud for the `Abstract` scheme and team, and create an archive workflow with App Store Connect distribution. Xcode Cloud manages its own build number. The first app record, signing setup, store listing, and review submission must be configured in App Store Connect.

Android builds in GitHub Actions. Configure the `mobile-android` environment with `ANDROID_KEYSTORE_BASE64` (base64 encoded upload keystore), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and `PLAY_SERVICE_ACCOUNT_JSON` (Google Play Developer API service account JSON). Create the app and an initial release in Play Console. Run Actions → Mobile with `publish_android=true` and choose a track; the workflow prebuilds Android, signs an AAB, uploads the artifact, and publishes it to Google Play. Its version code comes from the GitHub run number. Android and iOS store workflows do not change the Mac app's version or release process.

The pull request workflow checks TypeScript and the JavaScript bundle. Native builds require the respective Apple or Google credentials and store records.

## Interface

The mobile layout uses the Mac app's project/chat sidebar as a full-screen destination. Chat, worktrees, automations, pull requests, review, files, and terminals each use the full screen, with header controls to return or open the sidebar; there is no bottom tab bar. The sidebar button pops back to the sidebar, while a left swipe moves through the chat workspace views and a right swipe returns. The chat transcript uses the Mac app's tool symbols and verbs, and Files and edit calls use its Material Icon Theme manifest. Colors, Inter and JetBrains Mono fonts, SF Symbols, and the app icon come from the Mac app's interface and assets.

## Current coverage

The app pairs with a Mac, shows projects and chats, creates project or standalone chats and worktrees, follows agent output, sends follow-ups with files and images, answers permission prompts and questions, browses and edits files, accepts or discards changed files and sends line comments in review, opens a worktree terminal, manages chats and worktrees, creates and manages pull requests, and creates, edits, runs, pauses, and deletes automations on the host. It uses the same remote connection for nearby discovery and direct addresses. Attachments are limited to 8 MB per message by the remote frame size. Some Mac controls still need mobile screens, including detailed settings and review thread history.
