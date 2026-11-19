# Guarded automatic unlock

MacPearl's automatic unlock is an opt-in convenience feature. It is not
equivalent to Touch ID or Face ID: a laptop webcam is a two-dimensional
sensor, so a successful face match must not be treated as hardware-backed
authentication.

## Preparation

1. Enroll a face while signed in.
2. Enter the Mac password in the **Automatic unlock** field.
3. Choose **Store and Authorize** and approve the Keychain user-presence
   prompt while signed in.
4. Grant MacPearl Accessibility access in System Settings > Privacy & Security
   > Accessibility.
5. Choose **Authorize Session** before locking the Mac. Repeat authorization
   after quitting or restarting MacPearl.

The password is encrypted with AES-GCM. In free builds, the session encryption key is derived through a Secure Enclave P-256 operation protected by `userPresence` and `privateKeyUsage`. Only the device-wrapped private key, the peer public key, and encrypted password envelope are stored in a single traditional file-based Keychain record. There is no persisted plaintext session key. Signed development/Developer ID builds retain their existing user-presence-protected Keychain key unless explicitly packaged with the free backend. The authorized key and encrypted
credential remain in memory until MacPearl quits or the stored password is
removed. The password is decrypted only when needed for entry. Lock/unlock and
sleep/wake do not require another authorization during that app session.

Saving authenticates the protected key before updating the encrypted password. Existing keys are reused; free builds replace the entire record atomically only after authorization and encryption. Cancellation or a failed write preserves the previous credential. Canceling first-time setup does not store a password. The free backend requires a working Secure Enclave and fails closed if unavailable. It uses the separate `com.stevenha.MacPearl.enclave-credential.v1` service; earlier credential services are not silently migrated or deleted.

## Unlock gates

Password entry requires all of the following:

- CoreGraphics or the IOKit console state confirms the screen is locked, with
  a matching signed-in account verified through IOKit on both paths.
- A face template was loaded before the lock transition.
- The recognition stabilizer reports a match.
- The credential session is authorized and ready.
- Accessibility is trusted.
- No unlock attempt has already been made in the current lock session.

The app allows at most one password attempt until a confirmed macOS unlock.
Sleep, wake, an unavailable state query, or switching console accounts cannot
reset that budget. The user can always unlock manually. Startup/FileVault and
login after logging out are outside this user-session feature.

## Pause and remove stored data

In Settings, **Pause Automatic Unlock** stops scanning, clears session authorization and stays paused across app relaunches. **Resume Automatic Unlock…** requires fresh authorization, or routes to setup when a compatible face/password is missing. Completing setup explicitly enables automatic unlock again.

**Remove Stored Password…** and **Delete Saved Face…** each ask for confirmation and pause automatic unlock before attempting deletion. Face deletion requires re-enrollment; password deletion requires saving it again. If deletion fails, the app remains paused and shows the error; do not assume the data was removed. There is no combined Reset All Data command yet.

Before uninstalling, remove both stored items while the app is installed and turn off launch at login, then quit and delete MacPearl from Applications. Deleting the app alone leaves its Keychain items behind. macOS Camera and Accessibility permissions are managed separately in System Settings.

## Manual validation

### Camera startup timing

Camera startup probes confirmed lock state immediately, retaining bounded 150 ms retries when the state is not yet settled. A healthy running camera is reused instead of restarted, and an unchanged configured input/output graph is retained between starts. Recovery still restarts the session when needed. Camera shutdown behavior, capture quality and recognition thresholds are unchanged.

The Camera log category records configuration time, `startRunning` duration and request-to-first-frame time in milliseconds. The last measurement starts at the camera request, not the original lock notification; it can include permission-prompt delay on first use. Use repeated authorized lock/wake trials to compare startup. These changes remove avoidable work; no hardware speedup has been measured yet.

```sh
log stream --level info --predicate 'subsystem == "com.stevenha.MacPearl" AND category == "Camera"'
```

### Unlock checks

Test a correct password, a wrong password, missing Accessibility permission,
an unarmed credential session, another person's face, and a face that is not
visible. Confirm the app never logs the password and that manual unlock always
remains available.

Also test Fast User Switching: MacPearl must not enter the original account's
password into another account's lock screen. With an intentionally wrong stored
password, confirm sleep/wake does not submit it a second time before a manual
unlock. Cancel setup authentication and confirm the previous credential still
works, then retry setup successfully.


## Enrollment direction guidance

Enrollment now shows live arrows and a face-angle dot against the current pose's highlighted target band. It explicitly mirrors the preview so directions and centering guidance share one coordinate convention. The arrow reverses when the user passes the allowed turn range. Missing/multiple faces, centering, distance, lighting, chin angle and head tilt receive specific guidance instead of a generic turn prompt.

Only the existing capture gate's holding/accepted states show the hold-still progress ring or captured confirmation. Pose limits, quality thresholds, hold durations, model preprocessing and unlock behavior are unchanged. Processing suppresses further turn instructions and the three pose labels show progress.

Manual validation: start a fresh enrollment, hold forward, turn left then right, deliberately overshoot each side and move off center. Confirm the arrow points toward the required correction, the dot reaches the highlighted band, and hold progress appears only after all capture checks pass. Validate the physical turn direction on the supported camera; rendered and synthetic-yaw tests do not establish physical camera behavior.
