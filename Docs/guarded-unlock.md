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

The password is encrypted with AES-GCM. The encryption key is stored in the
Keychain with `userPresence` protection. The authorized key and encrypted
credential remain in memory until MacPearl quits or the stored password is
removed. The password is decrypted only when needed for entry. Lock/unlock and
sleep/wake do not require another authorization during that app session.

Saving authenticates the protected key before updating the encrypted password.
Existing keys are reused, and cancellation or a failed envelope write preserves
the previous credential. Canceling first-time setup does not store a password.

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

## Manual validation

Test a correct password, a wrong password, missing Accessibility permission,
an unarmed credential session, another person's face, and a face that is not
visible. Confirm the app never logs the password and that manual unlock always
remains available.

Also test Fast User Switching: MacPearl must not enter the original account's
password into another account's lock screen. With an intentionally wrong stored
password, confirm sleep/wake does not submit it a second time before a manual
unlock. Cancel setup authentication and confirm the previous credential still
works, then retry setup successfully.
