# MacPearl release status and remaining gates

Updated November 11, 2026. This is the canonical release checklist; [release-builds.md](release-builds.md) contains commands and recorded validation. MacPearl will remain permanently free. No binary has been uploaded or published by this work.

## Current status

The local release foundation exists, but MacPearl is **not ready for public downloads or automatic updates**.

Implemented:

- `MacPearl-Release` scheme: app-only archive and app tests; research remains in the original development scheme.
- Explicit hardened runtime for Release, preserving bundle/team/Keychain identities.
- Local test, archive, Developer ID export and app verification commands. Bash 3.2 regression checks cover optional arguments.
- Archive version/build overrides through `MACPEARL_VERSION` and `MACPEARL_BUILD_NUMBER`; About displays the bundled values. Published build numbers still need to be tracked and increased by the release owner.
- Enrollment and recognition reject incompatible model/preprocessing templates. Setup routes to re-enrollment after required permissions.
- Persistent Pause/Disarm, Resume with fresh authorization, Remove Stored Password and Delete Saved Face. Removal pauses first, clears authorization, cancels scanning and reports failures. Incompatible templates and damaged credentials can still be removed.

Implemented for the selected free route: local ad-hoc DMG creation with Applications shortcut, install instructions and checksum (`package-free`). Not implemented: notarization submission, hosted release CI, Sparkle, an update feed, or Check for Updates. Ordinary developer builds still default to 0.1.0 (1). Unsigned tests do not establish signed runtime or download behavior.

## Gate 1 — redistribution rights

The bundled buffalo_s / w600k_mbf MobileFaceNet weights are marked non-commercial research only. Written permission is pending. Confirm terms covering this exact model, Core ML conversion and redistribution in a permanently free app, or replace the weights. Free distribution does not establish permission. Record source revision, terms, hashes and conversion process; add third-party notices and a license for MacPearl's own code. Keep model uploads and public artifacts blocked meanwhile. [InsightFace policy](https://github.com/deepinsight/insightface#license).

## Gate 2 — selected free signing route and runtime

The owner chose free ad-hoc distribution without paid Apple Developer membership. Developer ID signing and notarization are optional future alternatives, not release prerequisites for this route. The existing paid export/verification commands are retained.

Use `archive-unsigned` followed by `package-free` from [the build runbook](release-builds.md). The packaging command copies the archived app and applies an ad-hoc hardened-runtime signature with the camera entitlement. It omits the Apple-prefixed shared Keychain group and selects the Secure Enclave credential backend. The hardware enforces user presence; its wrapped key and encrypted credential are stored together in the traditional Keychain. Packaging exercises real Keychain CRUD and noninteractive authentication rejection from the signed executable. Earlier free builds with error -34018 are superseded. Confirm Camera, Accessibility, protected Keychain behavior and development-to-ad-hoc migration on real devices. Different builds may require renewed permission/Keychain approval; a stable bundle identifier alone does not establish continuity.

## Gate 3 — actual free download pipeline

1. Run current tests and make an unsigned Release archive with an increasing build number.
2. Run `package-free` into a fresh directory. It creates and verifies an ad-hoc app and compressed DMG, includes installation instructions, and writes a SHA-256 checksum. No upload or install occurs.
3. After model redistribution rights are established, browser-download the exact DMG on another Mac/clean account without Xcode, retaining quarantine. Test Privacy & Security → Open Anyway, install, offline launch, permissions, enrollment, authorization, real unlock, manual upgrade and removal. Managed Macs may disallow approval. Never tell users to disable Gatekeeper globally.
4. Retain the exact artifact, checksum, source revision, toolchain and test results. Add real support/download URLs before publication. Local signing and image verification do not establish successful first launch or runtime behavior.

See [Apple's first-launch guidance](https://support.apple.com/en-us/102445). The free artifact has no Apple-verified publisher identity or notarization ticket.

Start with tested Apple silicon devices and macOS versions at or above 15. The deployment target is not a device test matrix. Prefer direct distribution: the app disables App Sandbox and uses private SkyLight APIs, while the [App Store rules](https://developer.apple.com/app-store/review/guidelines/) require sandboxing and public APIs.

## Gate 4 — user safety and removal validation

Tests do not establish where global keyboard events land. Verify password-field focus, account changes during submission, Unicode/non-US layouts, held modifiers, cancellation, missing permissions, wrong/changed passwords and one attempt across repeated sleep/wake. Manual unlock must remain available.

Liveness implementation is deferred to a later update by the owner's explicit decision. Disclose that the experimental beta has no liveness detection and photo/video replay resistance has not been established. Face matching is not hardware-backed authentication. Continue reliability testing with other faces, missing/multiple faces, low light and camera changes; do not advertise Face ID-equivalent security.

Exercise removal in a signed build, including partial Keychain deletion failures and relaunch while paused. A combined Reset All Data action is still absent; users can remove face and password individually. Disable launch at login before deleting the app. Deleting the app alone leaves Keychain data behind. Add a real icon, app category, privacy/removal/support instructions and release notes. Overlay failure must not block setup or determine unlock behavior.

## Gate 5 — optional in-app updates

Sparkle is proposed but **not integrated**. Before claiming update support:

- Add Sparkle to the shipping target with appropriate embedding/signing and a real Check for Updates action.
- Generate and securely retain the update-signing key; embed its public key. Configure a real HTTPS feed and hosted artifacts, not a placeholder URL.
- Generate and sign the appcast/update archives. Developer ID/notarization and Sparkle update signatures are separate requirements.
- Track increasing `CFBundleVersion` values, matching feed versions, supported OS versions, release notes and channels. Script overrides alone do not establish monotonic published versions.
- Test a previous signed build updating to the next signed build; wrong-signature rejection, offline behavior, skipped versions, installation failure, data compatibility and required reauthorization after restart.

Source: [Sparkle integration](https://sparkle-project.org/documentation/), [publishing and build numbers](https://sparkle-project.org/documentation/publishing/). Manual updates can serve an initial beta, but must be labeled as such.

## Publishing decision

Publish a small beta only after Gates 1–4 pass. GitHub Releases can host the DMG, checksum and notes if repository visibility fits the audience. A public prerelease remains public; invite-only downloads need real access controls. [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

A marketing site, accounts, Intel support and broad refactoring can wait. Payments are out of scope. Gate 5 is required when offering in-app updates. No release date is established while model rights and free-download device validation remain unresolved. Developer ID and liveness implementation are not required by the selected initial beta scope.
