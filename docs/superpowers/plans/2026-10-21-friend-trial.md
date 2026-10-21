# Friend Trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Execute in this managed worktree; keep the owner's installation untouched.

**Goal:** Package all current features into a portable arm64 Mac trial with first-run setup and honest distribution gates.

**Architecture:** Shared bundle-aware runtime resolver replaces build-machine paths without altering development behavior. Native setup registers the bundled Chrome bridge and guides permissions, speech assets and official Codex login. Separate release builder packages pinned standalone Python and produces DMG artifacts without installing them.

**Tech Stack:** Swift/AppKit/SwiftUI, Foundation Process, Python stdlib/unittest, standalone CPython, macOS codesign/hdiutil/notarytool.

**Spec:** `docs/superpowers/specs/2026-10-21-friend-trial-design.md`

## Global Constraints

- Apple Silicon/macOS 26+, complete existing feature set; no source/compiler/Python requirement for recipients.
- Preserve existing application, signing configuration, runtime data, native host and current PID.
- Runtime data/private identities must not enter source or artifacts; bundled resources must not contain build-machine paths.
- No distribution claim or public binary release before Developer ID notarization and second-Mac acceptance.
- No automatic sends, privacy approvals or account credential handling during setup/tests.

## Review Focus

- App relocated into a path with spaces, apostrophes and Chinese characters: helpers and host still resolve.
- Duplicate running copies or launching from DMG: no conflicting socket/host/service writes.
- Desktop exists but no compatible CLI/login: setup stays pending, shows actionable resolution.
- Extension files copied but Chrome not connected: never claim browser ready.
- Missing signing/notary credentials or tampered runtime archive: fail closed and label unsigned artifacts accurately.

### Task 1: Portable runtime without feature regression

**Files:** Create `Sources/ContextCapture/ApplicationRuntime.swift`; modify `AppMain.swift`, `SessionModel.swift`, `PromptRefiner.swift`, `DesktopConversationCatalog.swift`, `DesktopDraftPreparation.swift`, `DesktopMessageSending.swift`, `IntegrationChecks.swift`.

**Interfaces:** `ApplicationRuntime` resolves `resourceRoot`, `pythonURL`, `codexURL`, `helper(_:)` using injectable Bundle info/resources/desktop locations; packaged mode refuses legacy absolute path fallback. `makePythonProcess(script:arguments:)` configures bundled Python with ignored environment/user site and bundled helper path. Existing session projectRoot resolves via runtime for local fixture serving.

- [ ] Add native checks for packaged resource resolution after relocation, missing bundled Python, no legacy-path fallback, embedded desktop CLI discovery and unchanged development paths; observe failure.
- [ ] Implement resolver and route existing Python/CLI calls through it. Keep all existing command arguments and safety guards.
- [ ] Run native/core checks and verify all old behavior checks pass.

### Task 2: First-run integration and setup

**Files:** Create `Sources/ContextCapture/TrialSetup.swift`, `TrialSetupView.swift`, `BrowserInstallation.swift`; modify `AppMain.swift`, `SpeechCapture.swift`, `IntegrationChecks.swift`.

**Interfaces:** `BrowserInstallation.install(resourceRoot:pythonURL:support:manifestDirectory:)` prepares wrapper/extension/manifests at caller-provided locations; `TrialSetupModel` exposes real readiness statuses and user-invoked actions. `TrialSetupView` is shown on installed first launch and reopenable from menu. Static launch guard runs before normal services.

- [ ] Test native wrapper execution from a directory with shell metacharacters (real subprocess and synthetic protocol), extension ID derivation/origin, repeat installation path repair, staged-manifest safety and readiness requiring browser heartbeat, login/permissions/speech.
- [ ] Implement per-user installation, setup refresh/action states, official login launch, microphone/AX/Finder permission and speech-download buttons. User must explicitly trigger external actions.
- [ ] Add duplicate-process and mounted-DMG guards; add read-only `--diagnose-installation` path before service creation.
- [ ] Run full checks; ensure no tests mutate real user home, defaults or browser host.

### Task 3: Relocatable release package

**Files:** Create `tools/release.py`, `tools/python-runtime.json`, `Tests/test_release.py`, `docs/trial-installation.md`; modify `tools/check.sh` and README.

**Interfaces:** Separate release CLI `prepare` uses pinned runtime URL/SHA, accepts cache path, bundles scripts/assets under Resources and runtime under Frameworks; output only `build/release/`. `sign` requires explicit Developer ID, signs nested Mach-O code. `notarize` requires named existing keychain profile; `package` creates read-only DMG and checksum/status; publish-ready requires notarized artifact plus external acceptance evidence.

- [ ] Write Python tests for digest failure, escaping archive/symlink rejection, resources-only Info.plist, complete helper inventory, private-file exclusion, developer-ID fail-closed and publication gate; observe failure.
- [ ] Implement pinned download/extraction, app assembly, sign/notarize/package commands, licenses and Chinese setup guide. Never call local development signing helper or install bridge.
- [ ] Build unsigned app/DMG in worktree, copy app to unrelated Unicode/space path, run read-only diagnostics and bundled interpreter helper suite without source/system-Python dependency.
- [ ] Inspect archive private-content/path scan, mount/read/unmount DMG and compare original runtime hashes/PID.

### Task 4: Final verification and handoff

- [ ] Full `zsh tools/check.sh`, release `swift build`, relocated package checks; summarize exact limits.
- [ ] Fresh independent whole-branch review; fix material findings and rerun affected checks.
- [ ] Save public-safe verification report and commit source changes on `codex/` branch; preserve primary checkout. Do not publish binaries before remaining gates.
- [ ] Give user artifact path, status, account steps and second-Mac test checklist. Mark pending Developer ID/publication explicitly.
