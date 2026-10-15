# MacPearl

**Look at your Mac to unlock it.**

MacPearl is an experimental macOS menu bar app that unlocks your signed-in session with on-device face recognition. Enroll once, authorize your session, lock your Mac — then look at the camera to unlock.

> Camera-based recognition is a convenience feature, not a replacement for Touch ID or Face ID. Always keep your password available.

---

## Features

- **Local face unlock** — Recognition runs entirely on your Mac with Core ML and Vision. Nothing is sent to the cloud.
- **Menu bar companion** — Lives in the menu bar with guided onboarding for camera, Accessibility, enrollment, and credentials.
- **Guarded automatic unlock** — After a verified lock-screen face match, MacPearl can submit your stored password through Accessibility — only when the screen is locked, the console account matches, and the session is authorized.
- **Notch unlock overlay** — Animated feedback in the MacBook notch while scanning and unlocking.
- **Launch at login** — Optional start so MacPearl is ready when you wake your Mac.
- **Privacy-first credentials** — Your Mac password is encrypted with AES-GCM; the key lives in the Keychain behind user-presence protection and stays in memory only for the authorized app session.

---

## Requirements

- macOS 15 or later
- A Mac with a built-in or supported camera
- Xcode (latest stable) to build from source
- Camera and Accessibility permissions

---

## Getting started

1. Open `MacPearl.xcodeproj` in Xcode.
2. Select the **MacPearl** scheme and **My Mac** as the destination.
3. Press **⌘R** to build and run.
4. Complete setup from the menu bar:
   1. Allow **Camera** and **Accessibility**
   2. Enroll your face (three poses)
   3. Store and authorize your Mac password
   4. Choose **Authorize Session** when MacPearl starts (required after each quit)

For setup details and safety checks, see [Docs/guarded-unlock.md](Docs/guarded-unlock.md).

---

## How it works

```text
Lock / wake
    → Verify lock state + active console account (CoreGraphics / IOKit)
    → Local face recognition (Vision + InsightFace MobileFaceNet via Core ML)
    → Match + authorized credential session + Accessibility trusted
    → Submit password once per lock session
```

MacPearl runs in your user session. It does **not** install a system authorization plug-in or replace the login window. Startup, FileVault, and login-after-logout are out of scope.

---

## Project layout

```text
MacPearl/
├── MacPearl/                    Main menu bar app (SwiftUI)
│   ├── App/                     Entry point and session orchestration
│   ├── Features/
│   │   ├── Camera/              Capture, preview, face detection
│   │   ├── Identity/            Enrollment, embeddings, matching
│   │   ├── LockScreen/          Lock monitoring, credentials, unlock
│   │   ├── Notch/               Notch unlock overlay
│   │   └── Setup/               Onboarding and settings
│   └── Resources/               Assets and Core ML model
├── MacPearlTests/               App and unlock tests
├── Docs/                        Unlock design and spike notes
├── MacPearlAuthorizationPlugin/ Diagnostic research only (not used by the app)
├── MacPearlCameraBroker/        Diagnostic research only (not used by the app)
└── Tools/MacPearlAuthCtl/       Helper for diagnostic spike installs
```

The authorization plug-in and camera broker targets are retained as research artifacts. The shipping unlock path does not install or enable them. Background: [Docs/authorization-plugin-spike.md](Docs/authorization-plugin-spike.md).

---

## Security notes

- Face templates and credentials stay on-device.
- Automatic unlock requires an explicit authorized session each time MacPearl launches.
- At most **one** password attempt per lock session; sleep/wake does not reset that limit.
- Fast User Switching is guarded — MacPearl will not enter your password into another account’s lock screen.
- Manual unlock with your password always remains available.

---

## Tech stack

| Area | Technologies |
|------|----------------|
| UI | SwiftUI, AppKit, MenuBarExtra |
| Vision | Vision, AVFoundation, Core ML |
| Model | InsightFace MobileFaceNet (bundled `.mlpackage`) |
| Lock state | CoreGraphics, IOKit |
| Credentials | Keychain (`userPresence`), AES-GCM |

---

## Status

Experimental / early beta (`0.1.0`). Built for learning and personal use on a signed-in Mac session. Expect rough edges; contributions and feedback are welcome.

---

## License

Add a license of your choice before publishing widely. The bundled InsightFace MobileFaceNet model retains its own upstream license terms.
