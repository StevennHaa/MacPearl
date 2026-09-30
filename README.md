# MacPearl

MacPearl is an experimental macOS app to use FaceID for Macbook

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
```

Keep camera capture, enrollment, recognition, and unlock integration in separate feature folders as they are added. Shared infrastructure should only move into a `Core` folder after two or more features actually use it.
