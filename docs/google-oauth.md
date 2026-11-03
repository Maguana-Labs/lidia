# Google sign-in (built-in OAuth client)

Settings → Calendar → Google Calendar shows one button, **Sign in with Google**,
when the app ships its own Google OAuth client. Users never see Google Cloud
Console. This page is for whoever builds and releases LidIA: create the client
once, then put its IDs in the build.

Without a built-in client the button is hidden and Settings offers **Use the
Google account on this Mac** instead (System Settings → Internet Accounts, read
through Apple Calendar). Users who set up their own client keep it under
**Advanced: use your own OAuth client**; their values override the built-in one.

## How sign-in works

- Loopback redirect: LidIA listens on `127.0.0.1` on a random port and opens
  Google's consent page in the browser. Desktop clients accept any loopback
  port, so no redirect URI is registered.
- PKCE (`S256`) and a random `state` on every attempt.
- Scope: `https://www.googleapis.com/auth/calendar.readonly` only.
- Tokens are stored in the Keychain.

Google treats Desktop app clients as public clients: the client "secret" ships
in the app and is not confidential. PKCE is what protects the code exchange.

## Create the client (once)

1. In [Google Cloud Console](https://console.cloud.google.com), create a
   project for LidIA (or reuse one).
2. **APIs & Services → Library**: enable **Google Calendar API**.
3. **Google Auth Platform → Branding** (the OAuth consent screen): app name
   "LidIA", support email, app logo, and links to the privacy policy and home
   page. User type **External**.
4. **Data Access**: add the scope `.../auth/calendar.readonly`.
5. **Clients → Create client**: application type **Desktop app**, name
   "LidIA macOS". Copy the client ID and client secret.
6. **Audience**: while the app is in *Testing*, only listed test users (up to
   100) can sign in, and their refresh tokens expire after 7 days. To let
   anyone sign in, **Publish app**. `calendar.readonly` is a sensitive scope, so
   Google asks for verification (privacy policy, a short demo video of the
   consent flow, and an explanation of why the scope is needed). Until it is
   verified, users see an "unverified app" warning.

## Put the IDs in the build

Either edit `Sources/LidIA/Resources/Info.plist`:

```xml
<key>LidIAGoogleClientID</key>
<string>1234567890-abc.apps.googleusercontent.com</string>
<key>LidIAGoogleClientSecret</key>
<string>GOCSPX-...</string>
```

or keep the plist empty in git and set them when packaging. `run.sh` and
`scripts/create-release.sh` write these into the bundled Info.plist:

```bash
LIDIA_GOOGLE_CLIENT_ID=1234567890-abc.apps.googleusercontent.com \
LIDIA_GOOGLE_CLIENT_SECRET=GOCSPX-... \
./run.sh
```

`swift run` doesn't read Info.plist, so test sign-in with `./run.sh`.

## Check it

1. Settings → Calendar → Google Calendar shows only **Sign in with Google**.
2. Click it, approve in the browser, and the tab says "You're signed in".
3. Today lists Google events. If the same Google account is also in Internet
   Accounts, each meeting still appears once (`UnifiedCalendar.merge`).
