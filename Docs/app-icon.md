# MacPearl app icon

## Current icon

The owner selected the orange laptop/face-scan image on a white background on November 11, 2026, replacing the generated pearl design. The original is copied from `Downloads/MacPearl Logo.png` into `MacPearl/Resources/Branding/macpearl-logo.png`; builds do not depend on Downloads. All ten macOS app icon slots are generated from this repository copy.

The source PNG is excluded from app target membership so it remains available for regeneration without being copied into the built app. The compiled app icon still comes from the asset catalog.

Regenerate with:

```sh
python3 Scripts/generate-app-icons.py MacPearl/Resources/Branding/macpearl-logo.png
```

The replacement rehearsal is version 0.1.1 (6). No recognition, credential or unlock behavior changed.

## Previous design (superseded)

Generated with the built-in image generation tool on November 11, 2026. The final PNG assets are stored in `MacPearl/Resources/Assets.xcassets/AppIcon.appiconset/` and referenced by its `Contents.json`. Xcode already selects this catalog as the app icon. `Scripts/generate-app-icons.py` reproduces the required sizes from a square PNG using Apple's sips tool.

## Generation prompt

Use case: logo-brand. Create a finished macOS application icon for MacPearl, a local face-unlock menu bar app. Square 1024x1024 composition. A single luminous ivory pearl centered inside four restrained rounded camera focus corner marks, on a deep midnight teal rounded-square macOS icon tile. Elegant, minimal, sculptural pearl with subtle pearlescent shading, crisp substantial focus marks in pale sea-glass teal, strong silhouette readable at tiny sizes. Rounded square tile occupies 88 percent of canvas with transparent exterior corners and modest padding. No letters, no text, no Apple logo, no padlock, no extra objects, no watermark, no presentation mockup. This image is the actual app icon asset, front-on, centered, polished native macOS visual.

Transparent background requested. The generated source was 1280 × 1280; the catalog includes 16–1024 pixel outputs. The menu bar continues to use its existing monochrome symbol.
