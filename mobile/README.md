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

Mobile releases are independent of Mac releases. GitHub Actions builds and signs iOS, then uploads the archive to **App Store Connect** for TestFlight. The checked-in `ios/Abstract.xcworkspace` and `Abstract` scheme are used directly. The workflow runs only when manually dispatched from `main`; its version input sets the iOS marketing version, and the unique GitHub run ID sets the build number. It does not submit the app for App Review or alter the Mac release process.

For the first iPhone upload:

1. In Apple Developer, register the explicit App ID `sh.abstract.mobile` for team `4732X99X72` and create an **Apple Distribution** certificate plus an **App Store Connect** provisioning profile for that ID. Export the certificate **with its private key** as a password-protected `.p12` file. Do not use the Mac app's Developer ID certificate.
2. In App Store Connect, create the iOS app record for `sh.abstract.mobile` and create a team API key with at least the **App Manager** role. Download its `.p8` file and record its key ID and issuer ID. Apple only lets you download the private key once.
3. The GitHub `mobile-ios` environment is restricted to `main`, and its `APPLE_TEAM_ID=4732X99X72` variable is configured. Add these environment secrets:

   | Secret | Value |
   | --- | --- |
   | `IOS_DISTRIBUTION_P12_BASE64` | Base64 encoding of the `.p12` file |
   | `IOS_DISTRIBUTION_P12_PASSWORD` | Password used to export the `.p12` |
   | `IOS_PROVISIONING_PROFILE_BASE64` | Base64 encoding of the `.mobileprovision` file |
   | `APP_STORE_CONNECT_KEY_ID` | API key ID |
   | `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
   | `APP_STORE_CONNECT_API_KEY_P8` | Full contents of the downloaded `.p8` file |

   On macOS, create the two base64 values with `base64 < certificate.p12 | tr -d '\n'` and `base64 < profile.mobileprovision | tr -d '\n'`. Paste the output directly into the corresponding GitHub environment secret.

4. After this workflow is merged into `main`, run **Actions → iPhone App Store → Run workflow** on `main` with the App Store version, such as `1.0.0`. Wait for App Store Connect to process the upload, then assign the build to TestFlight testers there. Complete the store listing, privacy and export-compliance questions, screenshots, and review information in App Store Connect before manually submitting the tested build for App Review.

Keep the `.p12`, `.mobileprovision`, and `.p8` out of the repository. Renew the certificate and profile secrets when they expire. The older Xcode Cloud post-clone script remains available for local/Xcode Cloud use but is not part of GitHub deployment.

Android builds in GitHub Actions. Configure the `mobile-android` environment with `ANDROID_KEYSTORE_BASE64` (base64 encoded upload keystore), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and `PLAY_SERVICE_ACCOUNT_JSON` (Google Play Developer API service account JSON). Create the app and an initial release in Play Console. Run Actions → Mobile with `publish_android=true` and choose a track; the workflow prebuilds Android, signs an AAB, uploads the artifact, and publishes it to Google Play. Its version code comes from the GitHub run number. Android and iOS store workflows do not change the Mac app's version or release process.

The pull request workflow checks TypeScript and the JavaScript bundle. Native builds require the respective Apple or Google credentials and store records.

## Interface

The mobile layout uses the Mac app's project/chat sidebar as a full-screen destination, and the app opens on it. Its chat list comes first, with search and filters above it; New chat and a More menu (Automations, Worktrees, Pull Requests, Kanban) sit in its header, and Settings is its footer. Chat, worktrees, automations, pull requests, review, files, and terminals each use the full screen; there is no bottom tab bar. Each screen has one way back: a chat's sidebar button (or swipe back) returns to the list, and every other screen's Back (or swipe back) returns to the screen it was opened from. Opened from a chat, the list's sidebar button (or a left swipe) closes it and returns to that chat with whatever was open over it; it never opens a different chat, and after a cold launch or once that chat is deleted there is nothing to close. A left swipe moves through the chat workspace views and a right swipe returns. With Reduce Motion on, screens cross-fade instead of sliding. The chat transcript uses the Mac app's tool symbols and verbs, and Files and edit calls use its Material Icon Theme manifest. Colors, Inter and JetBrains Mono fonts, SF Symbols, and the app icon come from the Mac app's interface and assets.

## Current coverage

The app pairs with a Mac, shows projects and chats, creates project or standalone chats and worktrees, follows agent output, sends follow-ups with files and images, answers permission prompts and questions, browses and edits files, accepts or discards changed files and sends line comments in review, opens a worktree terminal, manages chats and worktrees, creates and manages pull requests, and creates, edits, runs, pauses, and deletes automations on the host. It uses the same remote connection for nearby discovery and direct addresses. Attachments are limited to 8 MB per message by the remote frame size. Some Mac controls still need mobile screens, including detailed settings and review thread history.
