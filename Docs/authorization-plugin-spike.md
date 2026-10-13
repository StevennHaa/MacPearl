# Authorization plug-in spike

The Phase 5 authorization plug-in and camera-broker targets are retained as diagnostic research only. They are not part of MacPearl's production unlock path and the main app never installs or enables them.

The spike established that:

- `SecurityAgentHelper` cannot reliably acquire camera permission directly.
- An Aqua-session broker can capture frames while the screen is locked.
- A named Mach service registered in the broker's GUI bootstrap context is not visible to the authorization helper's context.
- Moving the camera app into the parent background user context prevents it from loading as an Aqua camera agent.
- The diagnostic authorization mechanism always denies and preserves the normal login-window fallback.

MacPearl now uses a user-session architecture: the signed-in app observes lock
and wake signals, verifies the active console account and lock state through
CoreGraphics and IOKit, and performs local face recognition. The main app uses
an explicitly authorized credential session and Accessibility password entry;
the diagnostic plug-in and broker are not part of that path. See
[guarded-unlock.md](guarded-unlock.md) for setup and validation.
