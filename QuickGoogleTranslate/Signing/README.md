# Personal build identity

`identity.json` pins the public certificate fingerprint. `certificate.der` is the public certificate, not a private key. The RSA private key is generated directly in the login Keychain with the application tag `local.quickgoogletranslate.mac.codesigning.v1`. Setup creates access for the setup executable and `/usr/bin/codesign` on this dedicated new key. It never exports private material, changes other keys, or edits certificate trust settings.

`sign-app.py` signs the translating app and its uninstaller with the pinned certificate. Each designated requirement contains the exact certificate fingerprint and the bundle identifier. Content changes between versions do not change that requirement. A different signer using the same bundle identifier cannot satisfy it. The Sparkle Ed25519 update key is separate and remains unchanged.

Builds must fail when the key or pin is missing; they must not revert to ad-hoc signing. `CreateIdentity.swift` refuses to replace an identity when its pin already exists. Keep this build identity across updates and reinstalls. The application uninstaller does not remove developer signing keys.

Explicit one-time setup, on the original build Mac:

```sh
swiftc -O -module-cache-path .build/module-cache Signing/CreateIdentity.swift -o .build/create-signing-identity -framework Security
.build/create-signing-identity --create Signing
```

The setup can be run again to check/reuse the same identity. Do not delete `identity.json` to create a replacement key. Changing certificate identity requires a fresh Accessibility grant. This local signing identity is not Developer ID and does not provide Apple notarization.

Regression check:

```sh
python3 Tests/Signing/verify-identities.py
```

The check signs two different executables and verifies their mutually compatible requirements, rejects a different signer with the same bundle identifier, rejects tampered bundle metadata, and rejects missing/mismatched configuration. It does not grant Accessibility or alter TCC. A real permission-retention test requires granting the personal-signed application once and then installing a subsequent update with the same identity.
