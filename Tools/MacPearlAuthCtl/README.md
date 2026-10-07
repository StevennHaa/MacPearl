# macpearl-authctl

This root helper installs the Phase 5 diagnostic camera probe without enabling face unlock. `CameraProbe` always returns `kAuthorizationResultDeny`; `use-login-window-ui` remains available as the lock-screen fallback.

Build and validate locally:

```sh
swift build --package-path Tools/MacPearlAuthCtl -c release
Tools/MacPearlAuthCtl/.build/release/macpearl-authctl check /path/to/MacPearlAuthorizationPlugin.bundle
```

The mutating commands must be run as root:

```sh
sudo macpearl-authctl install-diagnostic /path/to/MacPearlAuthorizationPlugin.bundle
sudo macpearl-authctl status
sudo macpearl-authctl uninstall
```

Installation refuses unsigned, ad-hoc-signed, incorrectly identified, or wrong-Team-ID bundles. It backs up both authorization rights with SHA-256 checksums before changing anything and rolls back if any step fails. Do not install until a valid Apple Development identity and a tested recovery path are available.
