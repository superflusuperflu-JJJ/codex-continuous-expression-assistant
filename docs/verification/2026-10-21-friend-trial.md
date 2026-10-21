# Small-group trial packaging verification

## Implemented

Portable arm64/macOS 26+ application bundle with bundled CPython, all runtime helpers, Chrome extension and fixture assets. Runtime paths resolve from the current app bundle; Codex desktop CLI is discovered at runtime. First-run setup provides real connection/permission/login/model checks and explicit user actions. Existing capture, organization, editing, choices, target selection, protected auto-submit, receipt verification, sidebar, export and session features remain present.

Release tools assemble separately from local developer builds, never install/register the normal app, and label unsigned staging honestly. Formal signing and notarization require a Developer ID and an existing notary keychain profile. Clean-Mac acceptance is bound to a complete normalized bundle digest and every feature check. Native runtime dependency notices are included from the exact matching hash-verified upstream standalone full build.

## Executed checks

- Full regression: 73 core + 70 native + 17 browser + 40 Python = 200 checks, zero failures.
- Release Swift compilation succeeded. Built portable app contains no baked build-machine Python/Codex/project paths in Info.plist.
- Copied app into an unrelated directory containing spaces, non-ASCII characters and an apostrophe. Bundled Python imports, all 70 native checks and the existing packaged Python helper suite pass there.
- Read-only installation diagnostic does not initialize SessionModel, register a browser host, prompt permissions or submit a Codex request. Complete app file snapshot unchanged after diagnostics and isolated tests. Python runs with `-B -E -s` to avoid modifying sealed app resources.
- DMG successfully created and mounted read-only; application, Applications shortcut, Chinese setup guide, dependency notices and staging warning present. Unmounted after inspection. SHA256 checksum verified.
- Scanned complete staged app for known private user paths, original private UUIDs and secret/config filenames; no matches.
- Owner's installed binary/Info.plist, signing configuration, selected target and browser bridge hashes unchanged; existing running application process unchanged. Primary checkout remains unchanged.
- Independent whole-branch review and follow-up completed. Missing native dependency notices and translocated-launch handling corrected and verified.

## Explicitly pending

No Developer ID identity, Apple notarization, Gatekeeper download/open acceptance or full second-Mac real voice/browser/Finder-to-Codex test was performed. New setup screens have compiled and readiness/registration logic has automated coverage; actual first-run permission and account UI needs recipient-Mac validation. The staged DMG is not a normal downloadable trial release. No binary uploaded to GitHub Releases, no changes installed over the owner's app, no privacy database changes and no real Codex submissions during packaging validation.
