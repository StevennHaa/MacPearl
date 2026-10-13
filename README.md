# MacPearl

MacPearl is an experimental macOS app to allow FaceID for Macbook

## Requirements

- macOS 15 or later
- Xcode 27 or later

## Open and run

1. Open `MacPearl.xcodeproj` in Xcode.
2. Select the `MacPearl` scheme and `My Mac` destination.
3. Press Command-R.

## Project layout

```text
MacPearl/
├── App/                 App entry point and app-wide setup
├── Features/            User-facing features, grouped by feature
│   └── Home/            Initial screen
├── Resources/           Asset catalogs and future bundled resources
└── SupportingFiles/     Entitlements and other build support files
MacPearlAuthorizationPlugin/       Diagnostic authorization plug-in
MacPearlAuthorizationPluginTests/  Authorization lifecycle tests
```

Keep camera capture, enrollment, recognition, and unlock integration in separate feature folders as they are added. Shared infrastructure should only move into a `Core` folder after two or more features actually use it.

## Phase 5 user-session foundation

MacPearl uses a launch-at-login user-session architecture. Lock and wake
notifications trigger checks of the real lock state through CoreGraphics and
IOKit, with the active console account verified on both paths. Optional
automatic unlock requires face enrollment, Accessibility permission, and a
credential session authorized while signed in. Authorization lasts until
MacPearl quits or the stored password is removed. Sleep/wake does not reset the
one-attempt password limit; a confirmed macOS unlock does. This is a convenience
feature, not a replacement for Touch ID or Face ID. See
[setup and manual validation](Docs/guarded-unlock.md).

The previous authorization plug-in and camera broker remain diagnostic spike targets only. They are not installed or enabled by the main app. See `Docs/authorization-plugin-spike.md` for the findings and limitations.

## Phase 5.1A authorization plug-in spike

The `MacPearlAuthorizationPlugin` target exports the authorization plug-in entry point and recognizes only the `FaceUnlock` mechanism. This phase is diagnostic and always returns `kAuthorizationResultDeny`; it cannot unlock a session.

The target uses automatic signing. For Apple Development signing, add an Apple ID under Xcode Settings → Accounts and select the same Personal Team for the MacPearl app, plug-in, and test targets. A local build without a configured team is ad hoc signed and must not be installed as a system authorization plug-in.

Phase 5.1A does not include an installer and does not modify the macOS authorization database.
