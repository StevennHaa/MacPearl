<p align="center">
  <img src="MacPearl/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-128x128@2x.png" alt="MacPearl app icon" width="96" height="96">
  &nbsp;&nbsp;
  <a href="https://github.com/StevennHaa/MacPearl/releases/download/v0.1.3/MacPearl-0.1.3-13-arm64-experimental.dmg">
    <img src="MacPearl/Resources/Branding/download-mac.svg" alt="Download MacPearl 0.1.3 for macOS — Apple silicon" width="272" height="96">
  </a>
</p>

<h1 align="center">MacPearl</h1>
<p align="center"><strong>Look at your Mac to unlock your signed-in session.</strong></p>
<p align="center">Swift · SwiftUI · Vision · Core ML · Secure Enclave</p>

MacPearl is a native macOS menu bar app that connects local face recognition with a guarded automatic-unlock flow. Enroll your face, authorize the app, and look toward the camera when your Mac locks or wakes. Face processing runs on your Mac without a cloud service.

**Status:** Experimental beta, version 0.1.3 (13). The packaged app targets Apple silicon and macOS 15 or later and requires a working Secure Enclave.

> This beta has no liveness detection. Resistance to photographs and video replay has not been established. Keep your password available; webcam recognition does not provide Face ID or Touch ID assurance.

## Download and install

**[Download MacPearl 0.1.3 for Apple silicon](https://github.com/StevennHaa/MacPearl/releases/download/v0.1.3/MacPearl-0.1.3-13-arm64-experimental.dmg)**

[Release notes](https://github.com/StevennHaa/MacPearl/releases/tag/v0.1.3) · [SHA-256 checksum](https://github.com/StevennHaa/MacPearl/releases/download/v0.1.3/MacPearl-0.1.3-13-arm64-experimental.dmg.sha256) · [All releases](https://github.com/StevennHaa/MacPearl/releases)

Requires Apple silicon, macOS 15 or later, a camera, and a working Secure Enclave.

> **Signing notice:** This experimental beta is ad-hoc signed and is not notarized by Apple. It has no Apple-issued Developer ID, so macOS cannot verify an Apple-issued publisher identity or Apple notarization for this download. macOS may block it on first launch.

Drag MacPearl to **Applications**, eject the DMG, then open the app. If macOS blocks it as an unidentified developer and offers an override, use **System Settings → Privacy & Security → Open Anyway**. Managed Macs may prevent this. Keep macOS security protections enabled; if macOS reports malware or damage, stop and contact the project maintainer.

See the [installation and removal instructions](Docs/free-download-installation.txt) for setup, permissions, updates, and removing saved data. Updates are installed manually from GitHub Releases.

## The experience

- **Guided enrollment:** Capture three face poses with live turn arrows, angle feedback, and hold progress.
- **Automatic unlock:** Recognize an enrolled face during an eligible locked session and submit the saved password through Accessibility.
- **Notch feedback:** Show scanning, matching, and unlock progress in an animated overlay.
- **Session control:** Authorize once per app launch, pause or resume automatic unlock, and remove the saved face or password from Settings.
- **Launch at login:** Start MacPearl automatically after signing in.

## Engineering

The app combines camera processing, model inference, credential protection, and macOS session state:

- **Recognition pipeline:** AVFoundation captures frames; Vision checks face position, pose, landmarks, and capture quality. An InsightFace MobileFaceNet model runs through Core ML, followed by embedding comparison and temporally separated match checks. See [recognition policy](MacPearl/Features/Identity/FaceMatcher.swift).
- **Camera lifecycle:** Separate queues handle session configuration and frame analysis, with bounded sampling and recovery for interrupted or stalled capture. See [camera controller](MacPearl/Features/Camera/CameraSessionController.swift).
- **Credential protection:** Free DMG builds use a user-presence-protected Secure Enclave key operation to derive the AES-GCM encryption key. The Keychain holds the wrapped key, public key, and encrypted password together; the authorized session key stays in memory until the app quits. See [credential storage](MacPearl/Features/LockScreen/EnclaveProtectedCredentialStore.swift).
- **Unlock policy:** Lock state, active console account, permissions, and session authorization gate password entry. A locked session permits at most one password submission; sleep/wake does not reset that budget. See [unlock coordinator](MacPearl/Features/LockScreen/LockedSessionRecognitionCoordinator.swift).

The SwiftUI interface uses AppKit for window presentation. Combine connects published state, ServiceManagement handles launch at login, and OpenDirectory verifies the supplied login password. The optional lock-screen overlay resolves private SkyLight APIs dynamically; overlay availability does not authorize an unlock.

## Build and run

You need macOS 15 or later, a camera, and Xcode with the macOS SDK required by the project. The free DMG also requires Apple silicon and a working Secure Enclave.

1. Open `MacPearl.xcodeproj` in Xcode.
2. Select the **MacPearl-Release** scheme and **My Mac**, then press **⌘R**. This scheme builds the app without the diagnostic research targets.
3. Allow Camera and Accessibility access. After granting access in System Settings, return to MacPearl and select **Check Permissions**, then **Continue**.
4. Enroll your face, enter your Mac login password, and approve the native macOS authorization prompt. Finish setup after authorization succeeds.
5. Lock with **Control–Command–Q** and look toward the camera. Authorize the session again after quitting or restarting MacPearl.

See the [installation and removal instructions](Docs/free-download-installation.txt) for the ad-hoc DMG.

## Validation

The first beta candidate passed **101 app tests** with zero failures or skips on an Apple silicon Mac running macOS 26.6.2. Coverage includes recognition policy, lock-session attempt limits, credential recovery and cancellation, enrollment guidance, and removal behavior. Enrollment, onboarding, and unlock were also tested manually by the project owner.

Run the app suite and release CLI regression check from the repository root:

```sh
bash Scripts/release.sh test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -v
```

Local release tooling checks archive contents, signing, disk-image integrity, checksums, and disposable Keychain/Secure Enclave operations from the packaged app. These checks do not establish compatibility with every supported macOS version or resistance to spoofing. Run `bash Scripts/release.sh --help` for archive, packaging, and verification commands.

## Scope and limitations

MacPearl operates within an already signed-in user session. FileVault, startup login, and login after signing out still require macOS authentication. Manual password unlock remains available.

The beta DMG is ad-hoc signed, without an Apple-verified publisher or notarization. Updates are manual, and changed signatures may require renewed permissions. The private SkyLight overlay integration may change with macOS updates. Liveness detection is planned for a later update.

The authorization plug-in, camera broker, and `MacPearlAuthCtl` folders are retained as [diagnostic research](Tools/MacPearlAuthCtl/README.md). The shipping app does not install or enable them.

## Acknowledgments

Thank you to the projects and developers whose work informed MacPearl:

- **[InsightFace](https://github.com/deepinsight/insightface)** and its contributors provide the upstream face-recognition model. MacPearl uses the MobileFaceNet weights identified as `buffalo_s v0.7 / w600k_mbf`, converted to Core ML. The model research and pretrained weights belong to their upstream authors.
- **[Glance](https://github.com/jonnyoo/glance)** by **[Jonathan Zhou / jonnyoo](https://github.com/jonnyoo)** provided a reference for the face-unlock and notch experience, lock-screen presentation, and session authorization approach. Its [NotchSkyLight implementation](https://github.com/jonnyoo/glance/blob/main/glance/NotchOverlay/NotchSkyLight.swift) informed MacPearl's overlay integration. [Upstream MIT license](https://github.com/jonnyoo/glance/blob/main/LICENSE).
- **[SkyLightWindow](https://github.com/Lakr233/SkyLightWindow)** by **[Lakr Aream / Lakr233](https://github.com/Lakr233)** provided the private SkyLight window-space reference behind the optional lock-screen overlay. MacPearl resolves those interfaces locally rather than importing the Swift package. [Upstream MIT license](https://github.com/Lakr233/SkyLightWindow/blob/main/LICENSE).
- **[Apple's native frameworks](https://developer.apple.com/documentation/)** provide the interface, camera and inference pipeline, cryptography, Keychain, local authentication, system integration, and testing tools used throughout the app.

### Licensing

InsightFace publishes its code under MIT, while its pretrained models have separate [non-commercial research terms](https://github.com/deepinsight/insightface#license). The project owner has confirmed permission to redistribute the bundled weights with MacPearl. Upstream projects and model assets retain their respective terms.

MacPearl does not currently include a project-wide license. Upstream projects and model assets retain their respective terms.
