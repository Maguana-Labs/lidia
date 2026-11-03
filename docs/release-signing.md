# Release signing for in-app updates

LidIA updates itself with [Sparkle](https://sparkle-project.org). Sparkle checks
every downloaded update, and the appcast feed itself, against an EdDSA (Ed25519)
public key that ships inside the app. Without that key anyone who can tamper
with the feed or the download could push code to users, so **the updater stays
off until a real key is configured**.

## Current state

`Sources/LidIA/Resources/Info.plist` contains:

| Key | Value | Meaning |
|---|---|---|
| `SUPublicEDKey` | `DctQOMkD3Y6ljVkWaTPi42KRJj1QTgKDMfbWRG8kGYw=` | Public half of the key generated on 2026-11-03. The private half is in the release Mac's login Keychain. |
| `SUVerifyUpdateBeforeExtraction` | `true` | Check the archive's signature before unpacking it. |
| `SURequireSignedFeed` | `true` | Only accept an appcast signed with the same key. |
| `SUFeedURL` | `https://github.com/Maguana-Labs/lidia/releases/latest/download/appcast.xml` | Each GitHub release carries its own signed appcast; "latest" always points at the newest. |
| `SUEnableAutomaticChecks` | `true` | Installed copies check for updates on their own (users can turn it off in Settings → About). |

## One-time setup on the release Mac

Only the Apple account holder can do steps 1 and 2.

1. **Developer ID certificate.** Xcode → Settings → Accounts → select your team →
   Manage Certificates… → **+** → **Developer ID Application**. Check it landed:
   `security find-identity -v -p codesigning` lists "Developer ID Application: … (TEAMID)".
2. **Notary credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) → Sign-In and Security →
   App-Specific Passwords, then run this and answer its prompts (Apple ID,
   Team ID, that password); they are stored in the Keychain, never in the repo:

   ```bash
   xcrun notarytool store-credentials "LidIA-notary"
   ```
3. **Sparkle key.** Already done on this Mac (see below). Make the offline
   backup described under "Where the private key must never go".
4. `gh auth status` must show an account that can create releases in
   `Maguana-Labs/lidia`.
5. **iCloud sync.** A Developer ID provisioning profile for `io.lidia.app` with
   iCloud, and the CloudKit schema deployed to Production. Both steps are in
   [icloud-sync.md](icloud-sync.md) ("Developer ID profile", "CloudKit environments").
   `--no-icloud` builds a release without sync.

## Releasing

```bash
./scripts/create-release.sh 1.0.0             # build, sign, notarize, staple, signed appcast → dist/
./scripts/create-release.sh 1.0.0 --publish   # same, then a GitHub release with the DMG and appcast
./scripts/create-release.sh 1.0.0 --adhoc     # local test build only (not notarized)
```

The script stops before building if the certificate, the notary profile or the
Sparkle key is missing, or if the Keychain's Sparkle key doesn't match
`SUPublicEDKey`. It signs inside out (Sparkle's XPC services, Autoupdate and
Updater, the framework, `LidiaMCP`, then the app with hardened runtime),
verifies the signature, notarizes and staples the DMG, and fails if Apple
doesn't accept it. `CFBundleVersion` is the commit count, so every release
compares higher than the last.

## Generate the key pair (once, ever)

Run this on the Mac that will sign releases, after `swift build` has fetched
Sparkle:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It creates the key pair, stores the **private** key in that Mac's login
Keychain (item "Private key for signing Sparkle updates"), and prints the
**public** key. To print the public key again later:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

Put the public key in `Sources/LidIA/Resources/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>…44 base64 characters from generate_keys…</string>
```

The public key is not a secret; committing it is expected.

## Where the private key must never go

The private key is the only thing that lets someone ship an update every LidIA
user will install. Never put it:

- in this repository, any branch, a pull request, an issue, or a commit message
- in `Info.plist`, `.env` files, scripts, or build logs
- in a chat, ticket, email, or a shared drive
- on CI as a plain environment variable or an uploaded file artifact

Keep it in the release Mac's Keychain. Make one offline backup with
`generate_keys -x lidia-sparkle-private.key`, store that file in a password
manager or on encrypted offline media, and then delete the exported file. If CI
ever needs to sign, store the exported key as an encrypted CI secret and pass it
with `sign_update --ed-key-file`, never echoing it.

**Rotating the key.** Installed copies trust only the key they shipped with.
To move to a new key, generate a new pair, ship one release that contains the
new public key and is signed with the old private key, then sign later releases
with the new key. If the old key is lost, existing installs can't update in-app
any more: users must download the next version manually. If it leaked, treat
anything signed with it as hostile and ask users to reinstall from the website.

## Checking a build

```bash
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' .build/LidIA.app/Contents/Info.plist
spctl --assess --type open --context context:primary-signature --verbose=2 dist/LidIA-1.2.3.dmg
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify dist/LidIA-1.2.3.dmg "<signature>"
```

`SparkleSigning.publicKey(in:)` in `Sources/LidIA/Updates/UpdateController.swift`
accepts only a 32-byte base64 key that isn't the placeholder; its tests cover
that rule.
