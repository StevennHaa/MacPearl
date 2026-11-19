# Local release builds

MacPearl is intended to remain free. These commands prepare a direct-download release locally while model licensing is pending. They never install the app, change authorization rights, upload to Apple, or publish files.

## Prerequisites

Use a Mac with the project's required Xcode version selected. The first release scripts target Apple silicon (`arm64`) and retain the macOS 15 deployment target. This is build scope, not evidence of compatibility with every macOS 15+ version.

`MacPearl-Release` archives only the app and tests only `MacPearlTests`. The original scheme retains the research targets for development. Hardened runtime is explicitly enabled in the app's Release configuration; Debug remains suitable for the existing tests. Bundle identifier, signing team, entitlements and Keychain identifiers are unchanged.

## Commands

### Selected route: free ad-hoc DMG

The owner has chosen distribution without paid Apple Developer membership. No Developer ID or notarization is required by this local packaging path. Users must approve the unnotarized app through macOS Privacy & Security if permitted. This does not establish Gatekeeper acceptance or a verified publisher identity.

```sh
MACPEARL_BUILD_NUMBER=4 MACPEARL_VERSION=0.1.2 bash Scripts/release.sh archive-unsigned
bash Scripts/release.sh package-free /absolute/path/MacPearl.xcarchive /absolute/path/new-dmg-output
```

Use the archive path printed by the first command and a fresh output directory. Packaging copies the app, adds an ad-hoc hardened-runtime signature with camera permission, verifies it, and creates a compressed DMG with an Applications shortcut, installation instructions and an adjacent SHA-256 checksum. The source archive is unchanged. No certificates, network uploads, notarization or installation are performed. A checksum detects changes only when obtained from a trusted source; it does not authenticate the publisher.

The ad-hoc build omits the Apple-prefixed shared Keychain access-group entitlement; the source entitlement and paid signing route remain unchanged. The package selects `secure-enclave-v1`: a Secure Enclave operation enforces user presence while a traditional Keychain record holds only the device-wrapped key, peer public key and ciphertext. Packaging now runs a real noninteractive self-test from the final signed executable: Keychain CRUD and rejection of Enclave use without interaction. Test user-presence prompts and data removal on this build. Different ad-hoc builds can have different signing requirements: Camera/Accessibility permissions and Keychain access may need to be approved again. Test upgrades; do not assume development/Developer ID data migrates seamlessly.

The DMG includes [free-download-installation.txt](free-download-installation.txt). Keep artifacts local while model licensing is pending. Test the actual browser-downloaded DMG on another Mac before publishing. Liveness is deferred to a later update by the owner; the experimental beta instructions disclose its absence.

### Existing build and optional paid signing commands

Run from the repository root:

```sh
bash Scripts/release.sh test
bash Scripts/release.sh archive-unsigned
```

Each command prints a fresh output directory under ignored `build/release/`. Supply a new directory as the final argument to choose another location. Tests save `Tests.xcresult`; archives save `MacPearl.xcarchive`. Existing output directories are rejected to avoid stale results or overwriting previous artifacts.

The unsigned archive is for compilation and product-content checks. It is not a downloadable beta and does not validate hardened-runtime behavior, Keychain access or permissions at runtime.

When a local signing identity is ready:

```sh
MACPEARL_BUILD_NUMBER=2 MACPEARL_VERSION=0.1.1 /bin/bash Scripts/release.sh archive
bash Scripts/release.sh export /absolute/path/MacPearl.xcarchive /absolute/path/new-export-directory
bash Scripts/release.sh verify /absolute/path/new-export-directory/MacPearl.app
```

The signed archive uses existing Xcode signing settings. Export requests Developer ID Application signing for the existing team using `Scripts/ExportOptions.plist`. This requires installed signing assets; the script does not create certificates, allow automatic provisioning updates, or submit for notarization. An unsigned archive is a rehearsal, not the input to the supported signed-export procedure.

The version/build numbers above are examples: choose a build number greater than the last published release. Overrides apply to archives, not ordinary developer runs. Without them, the project defaults remain 0.1.0 (1). The script validates their syntax but does not contact a release service or establish monotonic published build numbers. Xcode may use Apple Development for the local archive; only successful Developer ID export and verification establish distribution signing.

Commands support macOS's system Bash 3.2. Dispatch regression checks use stubbed tools to exercise empty optional argument lists and quoting without requiring a signing identity:

```sh
python3 Scripts/tests/test_release_cli.py
```

The verifier checks bundle identity, version/build, camera usage text, menu bar configuration, arm64 binary, bundled model and absence of known research/test products. Archive inspection also rejects extra installed products. Signed verification requires a valid Developer ID signature, expected team, secure timestamp, hardened runtime, camera entitlement and no debug entitlement.

After licensing is resolved and notarization is performed separately:

```sh
bash Scripts/release.sh verify-notarized /absolute/path/MacPearl.app
```

This additionally checks the stapled ticket and local Gatekeeper assessment. It does not replace browser-download testing on a clean Mac/account. A structural inspection alone is available with `inspect`.

## Remaining gates

- Obtain the exact model redistribution permission before external uploads/distribution.
- Exercise the ad-hoc app's Camera, Accessibility and Keychain behavior, including upgrades and renewed permissions.
- Verify the final DMG and first-launch Privacy & Security approval on a clean Mac. Developer ID and notarization are optional future work, not prerequisites for the selected free route.
- Exercise the new pause/password/face removal controls in a signed build, and complete lock-screen account/focus/spoofing checks before releasing the beta.
- Test the exact downloaded, quarantined artifact on another Mac, including upgrade and removal.

See [the release plan](download-and-beta-release-plan.md) for the full sequence. No release CI is enabled yet: the model stays local during licensing review, and the first signed pipeline needs validation before adding hosted credentials and artifacts.

## Original foundation validation on November 11, 2026

- All 72 app tests passed with zero failures or skips using the new scheme on an arm64 Mac running macOS 26.6.2, with Xcode 27.2 and signing disabled.
- The unsigned Release archive succeeded and passed content inspection: only MacPearl is installed in archive products; the app reports 0.1.0 (1), arm64 and minimum macOS 15.0. The archive build graph contains only the app target.
- Effective Release settings report `ENABLE_HARDENED_RUNTIME = YES`. Because this rehearsal is unsigned, this does not validate a runtime signature or runtime compatibility.
- Distribution verification rejects the unsigned archive at signature verification. The script also rejects an existing archive output directory rather than overwriting it.
- Shell syntax and project/export plist validation passed. Xcode still warns about a missing app category; the icon catalog also needs real assets before release.

Developer ID export, notarization, browser-download installation and actual signed lock-screen behavior have not been validated. The current working tree includes the pre-existing AppSessionController change; it was preserved and included in this test run.

The original validation missed empty-array expansion failures under Bash 3.2 in signed archive and inspect dispatch. Those paths are now covered by the regression checks above. See the [current release checklist](download-and-beta-release-plan.md) for completed work versus remaining gates; the original validation is historical evidence, not public-download readiness.

## Review follow-up validation on November 11, 2026

- All 80 app tests passed after adding model/preprocessing upgrade recovery, compatible replacement, persistent pause, face deletion and password deletion success/failure coverage. Tests use fake stores and password validation; they do not establish signed Keychain behavior or lock-screen delivery.
- The CLI regression test passed on system Bash 3.2.57 across signed archive, unsigned archive, inspect, verify and verify-notarized dispatch, including paths with spaces, version/build overrides and invalid build-number rejection. External build/verification tools are stubbed in this regression test.
- A real signed archive invocation reached Xcode correctly with version 0.1.1 and build 2, then failed because no matching Mac App Development provisioning profile was installed. Provisioning updates were not requested. Developer ID export remains unverified and requires a usable Developer ID identity; the shell fix does not remove these signing prerequisites.
- A fresh unsigned Release archive succeeded with version 0.1.1 (2), arm64 and minimum macOS 15.0, and passed archive content inspection. A direct system-Bash `inspect` invocation on its app also passed. This validates local build/content handling only.


## Free distribution validation on November 11, 2026

- A fresh current-source unsigned app-only Release archive succeeded: 0.1.0 (1), arm64, minimum macOS 15.0. This rehearsal used default version numbers; choose an increasing build number for a published release.
- `package-free` successfully copied and ad-hoc signed the app, verified its signature/runtime/camera entitlement and created a DMG. `hdiutil verify` passed; the adjacent SHA-256 was generated. The local rehearsal is under ignored `build/release/free-beta-rehearsal/`.
- System Bash syntax and CLI regression checks passed, including the new packaging dispatch with paths containing spaces and rejection of missing arguments.
- Disk-image creation required execution outside the filesystem sandbox. Nothing was installed, opened or uploaded. The source archive was retained unchanged.
- App tests were not rerun for these packaging-only changes. First-launch approval, Camera/Accessibility permissions, protected Keychain behavior and upgrade/removal on another Mac remain unverified. This is a local rehearsal, not a public release.


## Credential backend correction on November 12, 2026

The previous free DMGs passed structural/signature checks but failed protected credential creation with error -34018. Removing entitlement-gated Keychain access was insufficient: `SecAccessControl` user-presence keys still selected the Data Protection Keychain. Those DMGs are superseded.

Free packaging now selects a dedicated backend. A non-permanent P-256 Secure Enclave key enforces `.userPresence` and `.privateKeyUsage`. ECDH and domain-separated HKDF derive the AES-GCM session key. The disposable software peer private key is discarded; only its public point, the hardware-wrapped private key blob and ciphertext are stored atomically in the traditional Keychain. No application-only authentication gate or plaintext-key fallback is used. New records use `com.stevenha.MacPearl.enclave-credential.v1`; old credentials are neither silently migrated nor removed. Unsupported devices fail closed.

The final executable supports `--credential-self-test` without starting onboarding, camera, login registration or unlock logic. Packaging runs the noninteractive variant automatically against a random disposable Keychain service. To test native authentication and an encrypted synthetic credential round-trip, run the packaged app executable with `--credential-self-test --interactive`; approve the two native prompts personally. The test removes its record on success or failure and never uses the user's real Mac login password as test data. Interactive results must be recorded separately from automated checks.

This build still requires ordinary install/permissions/enrollment/lock-screen testing. Approval of a synthetic credential test is not proof of password delivery or browser-download installation.

### Automated results for 0.1.2 (7)

- All 89 app tests passed with zero failures or skips on macOS 26.6.2 / arm64, including seven dedicated Enclave credential-store tests. These use injected cryptography for fault cases, not synthetic biometric approval.
- The current-source Release archive succeeded. Packaging selected `secure-enclave-v1`, ad-hoc signed the app and verified its runtime, camera entitlement and signature.
- The signed executable successfully created, read, updated and deleted a disposable traditional Keychain record. A protected Enclave operation failed with user-interaction-required when run noninteractively; error -34018 did not occur.
- The final DMG passed checksum verification. The same noninteractive self-test passed again from the app inside the read-only mounted DMG, then the volume was ejected.
- The native interactive test subsequently passed from the final mounted DMG: user-authorized synthetic credential save, fresh authorization, decryption and deletion. The disposable record was deleted and the volume ejected. No real Mac password, face enrollment, installation or automatic unlock was used in these checks.

Run the final-artifact interactive check while at the Mac:

```sh
bash Scripts/release.sh test-free-dmg build/release/free-beta-enclave/MacPearl-0.1.2-7-arm64-experimental.dmg --interactive
```

The command mounts the DMG read-only, verifies it, requests two user-presence approvals for a synthetic credential, deletes the temporary test record, and ejects the volume. If a prompt is canceled, it reports failure and cleans up; it does not fall back to unprotected storage.


## Enrollment guidance validation on November 13, 2026

Version 0.1.3 (8) adds live turn/position arrows, target-angle tracking, overshoot correction, capture-gate hold feedback, pose progress and an explicitly mirrored enrollment preview. All 98 app tests passed with no failures or skips, including nine new guidance/layout checks. Left, right and hold-state renderings were inspected at onboarding width. Release archive, ad-hoc signature, real noninteractive Keychain/Enclave self-check and DMG verification passed. The local artifact is `build/release/free-beta-enrollment-guidance/MacPearl-0.1.3-8-arm64-experimental.dmg`.

Physical enrollment direction and capture behavior still need a user trial on the supported camera. Capture thresholds, model preprocessing and recognition/unlock behavior were not changed. Existing ad-hoc Accessibility approvals may require removing and re-adding the installed app after its signature changes; this build does not bypass that macOS requirement. No public artifact was uploaded.
