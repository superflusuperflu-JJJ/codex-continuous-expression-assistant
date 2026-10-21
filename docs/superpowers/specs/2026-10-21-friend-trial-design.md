# Friend trial distribution design

## Approved user scope

Produce a complete small-group macOS trial of Codex连续表达助手. Change installation and first-run experience, with no existing feature removed. Do not replace, restart, reauthorize, or mutate the owner's currently installed application, runtime data, browser bridge, signing identity or selected Codex chat. User has no Apple Developer Program membership; build and test everything possible now, but Developer ID signing, notarization and clean second-Mac acceptance remain explicit release gates.

## Deliverable and journey

Apple Silicon/macOS 26+, Chrome, installed signed-in Codex desktop. Deliver a DMG containing the app, an Applications shortcut and brief Chinese setup instructions, plus checksum and release status. User drags app to Applications, opens it, completes a visible setup checklist, loads the packaged Chrome extension following a short guide, grants macOS permissions and prepares the Chinese speech model. No Swift, Node, Python, Homebrew or source checkout is required on the recipient's Mac. Actual Codex account and system permissions remain user controlled. A separate Codex CLI installation should not be required when the installed desktop app includes a compatible executable; discover that executable at runtime, with an explicit alternate-file picker if discovery fails.

Keep all current capture, association, editing, semantic organization, choice cards, target selection, existing-draft protection, one-shot submission, receipt verification, session persistence, export and drawer features. The full existing check suite remains required. Setup completion does not silently turn off failing features; required missing checks remain actionable, with an explicit way to inspect the main interface without claiming setup complete.

## Portable runtime

Bundle the helper scripts, browser extension, test-page assets and a pinned SHA256-verified standalone CPython 3.13 arm64 distribution inside the app. Keep redistribution license files. Production resolves bundle resources first and never falls back to build-machine paths. Local developer builds retain their existing paths via one shared runtime resolver. Discover desktop app through Launch Services and known /Applications and ~/Applications locations; check its embedded native CLI and known user CLI paths. Recheck paths per operation to tolerate desktop updates. Login checks use `login status`, do not read or print credential files. Account login uses the official CLI/browser flow only after an explicit user click, without collecting passwords or account tokens.

## Setup and native messaging

First installed launch shows a normal setup window, independent of auto-hide settings. Checklist: supported OS/architecture and install location; bundled runtime integrity; Chrome presence and local host registration; browser extension connected (not merely copied); Codex desktop, compatible executable and login; auxiliary accessibility and microphone permissions; Chinese speech model; Finder automation permission. Use truthful ready/pending/error states, recheck when returning from System Settings, and allow reopening setup from the menu. Permission requests, speech download and browser actions happen only when the user clicks the corresponding button.

Write native messaging registration at first launch, not on the build machine. The executable host is a shell wrapper with properly quoted paths invoking bundled Python and the bundled host script; preserve stdout for Chrome protocol. App moves are repaired on the next launch. Do not overwrite an active user's bridge from a second simultaneous copy: before creating SessionModel or setup services, refuse a duplicate running app using the same bundle identity. Refuse normal launch from a mounted DMG with instructions to drag to Applications first. No repeated privacy reset or broad security bypass instructions.

## Distribution and isolation

Work in an isolated managed worktree and write artifacts only under that worktree's ignored build directory. Retain existing bundle ID, data conventions and developer build script behavior. Add a separate release builder that never registers local native messaging, installs extensions, launches the new app or touches private local signing configuration. Default release preparation is explicit unsigned staging; it must never silently fall back from Developer ID signing to unsigned. Signed distribution accepts an existing Developer ID identity, signs all nested Mach-O components with hardened runtime and appropriate audio/automation entitlements, then supports notarytool keychain-profile submission and stapling. Never include credentials, developer home paths, personal sessions or signing keys in artifacts. No GitHub downloadable release is published while notarization or clean-machine acceptance is missing.

## Acceptance and evidence

1. Existing 173 checks pass, plus tests for runtime resolution, native host quoting, setup readiness, safe archive extraction and release gates.
2. Copy the bundle to an unrelated path containing spaces and non-ASCII characters; run bundled Python and all helper tests without project paths or system Python; check no build paths in Info.plist/configuration.
3. A read-only installation diagnostic can run without creating normal app services, requesting permissions, touching browser registration or sending Codex messages.
4. Inspect/sign-verify package as appropriate; mount DMG read-only to verify contents, then unmount.
5. Recheck original app, signing configuration, selected target and browser bridge hashes and original running PID unchanged.
6. Full real voice/browser/Finder-to-Codex acceptance on another Mac is required before claiming recipients can install and use it; arrange with the user once signing prerequisites are available. Missing membership is not a reason to stop portable runtime and setup development.

## Builder decisions

Keep setup native SwiftUI/AppKit with Chinese plain-language copy. Use the project's executable behavior-check style for Swift tests and unittest for packaging. Use the existing unpacked Chrome extension flow for the first small group, with an in-app step list and direct folder/extension-management buttons; Web Store publication is a later improvement, not a prerequisite for retaining browser features. Avoid new system-wide services or login items. Do not upload diagnostic payloads automatically.
