# iCloud sync

LidIA's Mac and iPhone apps keep one library in step through **CloudKit**, in the
private database of the user's own iCloud account (container `iCloud.io.lidia.app`).
There is no LidIA server. SwiftData does the syncing (Core Data's
`NSPersistentCloudKitContainer` underneath); LidIA decides when it's on, makes it
safe, and shows its status.

The self-hosted lidia-sync server still works as an alternative
(Settings › Sync › Advanced on the Mac, Settings › Self-hosted sync on the iPhone). It
pauses while iCloud sync is on: both would bring the same meetings in.

## What syncs

| Syncs | Doesn't sync |
|---|---|
| Meetings: title, date, attendees, notes, transcript (words and text), summary, user edits, folder, template, status | Audio recordings (they stay on the device that recorded them) |
| Action items, with their board column, completion and AI provenance (`aiFingerprint`) | Settings, API keys (they have their own "Sync API keys with iCloud" option) |
| Ask chats, inbox notifications, talking points | SOUL.md / MEMORY.md (self-hosted sync only) |

Apple encrypts the data in transit and on its servers. It's **end-to-end encrypted
only when Advanced Data Protection** is on for the Apple Account. The Sync settings say so.

## The schema

One definition, in `Packages/LidIAKit/Sources/LidIAKit/Models`, used by every app. The
Mac re-exports LidIAKit (`Sources/LidIA/Models/SchemaVersioning.swift`), so there is
no mirror to keep in step. `LidIASchemaV4` lists the models.

CloudKit's rules, enforced by `LidIASchemaTests` (LidIAKit) and `CloudKitSchemaTests`
(Mac), which walk the Core Data model SwiftData builds and also run Core Data's own
CloudKit validator:

- every attribute is optional or has a default;
- every relationship is optional and has an inverse (to-many sides are stored as
  `actionItemsStorage` / `messagesStorage`; use `actionItems` / `messages`);
- no unique constraints, no ordered relationships, no Deny delete rule;
- **append only**: never rename or remove a field. A renamed field is a new, empty
  CloudKit field, and older app versions keep writing the old one. The tests keep a
  frozen field list (`expectedFields`); a new field means updating it on purpose.

Large values: SwiftData keeps big transcripts in the SQLite file or next to it
(`.externalStorage` applies to binary values such as the word array). CloudKit
records are limited to 1 MB; Core Data moves any string or binary value too large for
a record into a CKAsset by itself, so long transcripts sync.

### Device-local fields

- `audioFilePath` is the path on the device that recorded the meeting. It syncs but
  never resolves elsewhere: the Mac only plays a file that exists
  (`MeetingAudioLocator`), the iPhone only treats a meeting as recorded here when it's
  this device's.
- `originDeviceID` names the device that created a meeting (`LidIADevice.id`, a random
  per-install identifier). Launch recovery on each device (recording and processing)
  only touches its own meetings, so a meeting the iPhone is still recording or
  processing is never failed or re-processed by the Mac. Meetings that existed before
  sync are claimed by the device they're on, once (`LegacyMeetingOwnership`), before
  recovery runs.

## Conflicts

CloudKit sync here is **last writer wins, per field**: each device uploads the fields
it changed, and the newest save of a field wins everywhere.

- Two devices editing *different* fields of a meeting (notes on the iPhone, title on
  the Mac) both keep their change.
- Two devices editing the *same* field before either has synced: the later save wins
  and the other edit is lost. Notes and summaries are single text fields, so editing
  the same meeting's notes on both devices while one is offline is the case to avoid.
- The old self-hosted sync could overwrite unsynced local edits with the server's copy.
  CloudKit doesn't do that: a device's own saved edits upload as soon as it can reach
  iCloud, and imports only replace fields another device changed after them.
- Regenerate keeps action items the user completed, edited or added because
  `aiFingerprint` and the item's fields sync together: an edit on the iPhone changes
  the fields, the fingerprint no longer matches, and the Mac's Regenerate keeps the item.
  `userEditedSummary` / `userEditedTranscript` sync the same way. Undo after Regenerate
  restores fields on the device that regenerated, and that restore syncs like any edit.
- Deleting a meeting deletes it everywhere (its action items too). Recovery from a
  mistaken delete is the library backups, not iCloud.
- No unique constraints means two devices could, in theory, both create an object with
  the same `id` (only through the self-hosted server and iCloud at once, which is why
  they're exclusive). Chat threads are looked up by `id` before inserting.

## When sync runs

Decided once at launch (SwiftData can't switch CloudKit on or off for an open library;
changes apply at the next launch):

- **Mac** (`LibrarySyncMode.resolve`): the build carries the iCloud entitlement
  (checked at runtime; a build without it never touches CloudKit), Local-only mode is
  off, and "Sync with iCloud" is on. New installs: on. An existing library: off, and the
  main window asks once ("Turn on iCloud sync?").
- **iPhone**: "Sync with iCloud" (on by default) and Local-only off.
- Turning on Local-only mode on the Mac while syncing asks to restart LidIA (or keep
  sync and leave Local-only off). On the iPhone it stops sync at the next launch.

Before the first launch with schema 4, and again before the first launch that syncs,
the Mac copies the library to `Library Backups/before-schema-4-<time>` and
`before-icloud-sync-<time>` (never pruned) and checks each copy with SQLite's
`quick_check`. If the backup before the first sync fails, sync stays off that launch
and Settings says why. If opening with CloudKit fails, the library opens without sync
and Settings shows the error.

Turning sync on for an existing library uploads it: Core Data exports every existing
object the first time a store is opened with CloudKit (SwiftData stores already keep
persistent history, which the mirroring uses).

## Signing

macOS honors iCloud entitlements only in an app that embeds a matching provisioning
profile (`Contents/embedded.provisionprofile`), even outside the App Store. SwiftPM
can't make one, so `scripts/icloud-provisioning` is a tiny Xcode project (never
shipped) that lets Xcode's automatic signing register `io.lidia.app` with iCloud and
push and download the profile. `scripts/fetch-icloud-profile.sh` wraps it.

- **run.sh** signs with the Apple Development identity, fetches the development
  profile (registering this Mac with the team if needed), embeds it and adds the iCloud
  entitlements the profile allows, for CloudKit's **Development** environment. With no
  profile, or `LIDIA_ICLOUD=0`, it signs without iCloud and the app doesn't sync.
- **create-release.sh** embeds a **Developer ID** profile with iCloud and signs for the
  **Production** environment (required outside the App Store), then checks the signed
  entitlements. `--no-icloud` builds a release without sync.

Check a signing recipe without running LidIA (which would open the library): the
stub's `--check-icloud` mode, re-signed the same way, reports the CloudKit account.

### Developer ID profile (one time, in the developer portal)

Xcode's command line couldn't create it here ("No Accounts" from `-exportArchive`), so
make it once by hand:

1. [developer.apple.com/account](https://developer.apple.com/account) ›
   Certificates, IDs & Profiles › **Profiles** › **+**.
2. Under **Distribution**, choose **Developer ID** › Continue.
3. Profile type **Mac**; App ID **io.lidia.app** (`<TEAM_ID>.io.lidia.app`) › Continue.
4. Certificate: your **Developer ID Application** certificate › Continue.
5. Name: `LidIA Developer ID iCloud` › Generate › Download.
6. Move the file to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
   (or set `LIDIA_DEVELOPER_ID_PROFILE=/path/to/file`).

`scripts/fetch-icloud-profile.sh developer-id` then finds it.

### CloudKit environments and the schema

- run.sh builds and Xcode-installed iPhone builds use the **Development** environment;
  Developer ID releases and TestFlight/App Store builds use **Production**. They are
  separate databases: data synced by development builds isn't in Production.
- Development creates record types as data arrives. **Before the first release with
  sync**, deploy the schema: [CloudKit Console](https://icloud.developer.apple.com) ›
  iCloud.io.lidia.app › Schema › **Deploy Schema Changes…** to Production. Do it after a
  development build has synced at least one of each record type (meeting, action item,
  chat, notification, talking point), so every field exists. Repeat after any schema
  change.

### Push

The Mac's profile includes push (`aps-environment`), so the Mac hears about the
iPhone's changes while it runs. The iPhone build doesn't have push yet (it pulls changes
when the app opens): adding it needs Xcode to turn on Push Notifications for
`io.lidia.ios`, which failed with "No Accounts". After re-signing in under Xcode ›
Settings › Accounts, add `aps-environment` (`development`) to
`LidIAiOS/Resources/LidIAiOS.entitlements` and `remote-notification` to
`UIBackgroundModes` in `LidIAiOS/Resources/Info.plist`, and build with
`-allowProvisioningUpdates`.

## Checking a migration on a real library

The migration from schema 3.3 is lightweight (tested on a fixture written by the old
models). To check it on a real library, give the test a **copy** (it refuses the live
one and copies it again before opening):

```bash
mkdir -p /tmp/lidia-copy
sqlite3 "file:$HOME/Library/Application Support/LidIA/LidIA.store?mode=ro" ".backup '/tmp/lidia-copy/LidIA.store'"
LIDIA_MIGRATION_STORE=/tmp/lidia-copy/LidIA.store swift test --filter realLibraryCopyMigrates
```

It compares every meeting, action item and chat message column by column with plain
SQLite before and after, and prints the counts.
