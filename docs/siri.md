# Siri and App Intents

LidIA exposes its meetings, action items, people and projects to Siri, Shortcuts and Spotlight through App Intents, on the Mac and the iPhone. It is ready for Apple's Siri AI Developer Preview (announced 2026-11-03). The parts that need the 27.3 SDK are written but switched off; one command switches them on.

## What works today (Xcode 27.2, macOS/iOS 27.2)

Everything below builds with the 27.2 SDK and ships in both apps.

### Intents

| Intent | Mac | iPhone | Notes |
|---|---|---|---|
| Record a Meeting | ✓ | ✓ | Opens the app (foreground). |
| Stop Recording | ✓ | ✓ (Live Activity) | iPhone: a `LiveActivityIntent`, so it runs while the recording Live Activity is up. |
| Add Note to Live Meeting | ✓ | ✓ (Live Activity) | Adds `- [12:34] text` to the live meeting's notes. |
| Bookmark This Moment | ✓ | ✓ (Live Activity) | Adds `- Marked moment at 12:34`. |
| New Note | ✓ | | Opens a note (and may start transcribing, per Settings › Recording). |
| Find Meetings | ✓ | ✓ | By person, project, words and date range. Returns meetings. |
| Get Meeting Summary | ✓ | ✓ | Summary, decisions, action items. **Requires authentication.** |
| List Action Items | ✓ | ✓ | Mine or everyone's, by person, project, meeting, due date. |
| Add Action Item | ✓ | ✓ | Optional meeting, owner, due date. |
| Mark Action Item Done | ✓ | ✓ | |
| Open Meeting | ✓ | ✓ | `OpenIntent`. |
| Ask LidIA | ✓ | ✓ | Mac: the agent harness with the Ask route. iPhone: the Ask tab's engine. **Requires authentication.** |
| Draft Follow-Up | ✓ | | Opens a review sheet in LidIA. Never sends. |
| Prepare Next Step | ✓ | | Opens the Intents engine's confirm sheet for an action item. Never sends. |

Shared intents and entities live in `Packages/LidIAKit/Sources/LidIAAppIntents` (an `AppIntentsPackage`). Mac-only intents are in `Sources/LidIA/Siri/`; iPhone ones are in `LidIAiOS/Sources/App/AppIntents.swift` and `LidIAiOS/Shared/RecordingActivity.swift`. Each app plugs in a `LidIASiriHost` that supplies its library, navigation and Ask: `MacSiriHost` on the Mac, built in `LidIAApp.init`, and `IOSSiriHost` on the iPhone, built in `AppServices.init`. Both are ready before any window exists, so an intent that launches the app finds them.

### Entities

- **`MeetingEntity`** (`IndexedEntity`): title, date, duration, attendees (the user left out), project, status, open action items.
- **`ActionItemEntity`**: title, owner, due date, status, the meeting it came from, meeting title, project.
- **`PersonEntity`**: someone from meeting invites (not a contact), keyed by email or name. Has a meeting count and the last date you met.
- **`ProjectEntity`**: a meeting folder that names a project (`Meeting.folder`, minus import folders).

Each entity has an `EntityStringQuery` with suggestions. People and projects also have an `EnumerableEntityQuery`.

Queries work on value copies of the library (`SiriMeetingRecord`, `SiriActionItemRecord`), never on models held across actors. This is the same idea as `SpotlightIndexer.Entry`.

### Spotlight, onscreen context, donations, transfer, snippets

- **Spotlight.** `Sources/LidIA/Search/SpotlightIndexer.swift` still indexes each meeting from its `Entry` value copy. Each item is now associated with its `MeetingEntity` (`SiriSpotlight.searchableItem`). The summary goes into the index only while Siri may read content (see Privacy). Turning the setting or Local-only mode on or off re-indexes the library.
- **Onscreen.** The meeting page sets `.appEntityIdentifier` and a `NSUserActivity` (`io.lidia.app.view-meeting`, declared in Info.plist). Action item cards and rows set their entity. The iPhone meeting page does the same.
- **Donations.** Mac: record, stop, new note, open a meeting, ask (only when Siri may read content), mark done, open a prepared next step, open a follow-up in Mail. iPhone: record, stop, open a meeting. Donations are off in demo and snapshot runs.
- **Transferable.** `MeetingEntity` exports a recap as plain text and HTML. `ActionItemEntity` exports a short card. The recap includes the summary and decisions only when the policy allows.
- **Snippets.** Brand cards (her red, ivory text on the mark) for found meetings, the summary, action items and confirmations. They are in `SiriSnippets.swift` and built from `LidIABrand.Hex`.

### App Shortcuts (English and Spanish)

Phrases that need no setup. They are in `LidIAShortcuts` in each app.

- Mac Spanish: `Sources/LidIA/Resources/AppShortcuts/es.lproj/AppShortcuts.strings`. `run.sh` copies it into the bundle.
- iPhone Spanish: `LidIAiOS/Sources/App/AppShortcuts.xcstrings`.

## The Mac build: where `Metadata.appintents` comes from

Xcode runs `appintentsmetadataprocessor` after linking. `swift build` does not, and an app without `Contents/Resources/Metadata.appintents` has no intents as far as macOS is concerned. SwiftPM's default build system (Swift Build) already compiles every target with `-emit-const-values`, which is the processor's main input. `scripts/lib/appintents-metadata.sh` does the rest of Xcode's steps, with the arguments taken from the iOS project's `xcodebuild` log:

1. It extracts `LidIAAppIntents` on its own (`.build/appintents/<config>/LidIAAppIntents.appintents`), like Xcode's per-package `.appintents`.
2. It extracts `LidIA`, merging step 1 as a static dependency, into `LidIA.app/Contents/Resources/Metadata.appintents`.
3. It copies the App Shortcut phrases per language and validates them with `appshortcutstringsprocessor`.
4. It runs `appintentsnltrainingprocessor`, which builds Siri's phrase-matching assets.

`run.sh` (Debug) and `scripts/create-release.sh` (Release) call it before signing. Both fail loudly if it fails, because an app without metadata builds and runs but silently has no intents. The script needs SwiftPM's default build system. With `--build-system native` there are no const values and it says so.

**How this was verified.** A renamed copy (`io.lidia.app.siri-test`, built from this tree) was signed with the Apple Development identity like `run.sh` signs, then registered and launched once. A DEBUG build with an `io.lidia.app.*` bundle ID opens an in-memory library. `linkd`'s log then showed:

```
Emitting indexing summary [incremental]: bundles=1 failures=0 ... intents=14 entities=4 enums=3 queries=4
Queuing notification for LNMetadataChangedNotification added: ["io.lidia.app.siri-test"]
Interpolating AppShortcuts for io.lidia.app.siri-test:en-US
```

`linkd` skips a bundle that is ad-hoc signed or has never been launched: it logs "not trusted for binding". So the real app is registered after `./run.sh` signs it with your Apple Development identity and it launches.

To check your own build:

```bash
./run.sh            # builds, adds the metadata, signs, launches
/usr/bin/log show --last 5m --style compact --process linkd | grep -i "io.lidia.app\b\|indexing summary"
```

Then open Shortcuts. LidIA's actions should be under Apps › LidIA.

**Spanish phrases from a build in `~/Documents`.** `linkd` is sandboxed and can't read `AppShortcuts.strings` inside `~/Documents`. It logged "Unable to issue sandbox extension" for the test copy, which lived under the repo. English phrases are inside the metadata itself, so they work everywhere. Spanish phrases work from an app in `/Applications`, which is where a release build is installed.

## Privacy

Siri can process requests on Apple's servers, so meeting content handed to Siri counts as leaving the device.

- **Always available to Siri:** meeting titles, dates, durations, attendees' names, projects, and action items (title, owner, due date, status). This is what Siri needs to find things and what the user asks to change. Find Meetings also matches words against notes and transcripts, but it returns only titles and dates.
- **Content:** summaries, decisions, notes, transcript excerpts and Ask answers. Siri gets these only when Local-only mode is off **and** "Let Siri read meeting content" is on. That setting is in Settings › Privacy on both apps, is on by default, and has a Settings search entry and a row in "What leaves this Mac". `SiriContentPolicy` enforces it. When content is blocked, intents return the titles and dates plus a short, plain message: "Local-only mode is on, so LidIA keeps meeting content away from Siri. Open the meeting in LidIA to read it."
- **Authentication:** Get Meeting Summary and Ask LidIA set `authenticationPolicy = .requiresAuthentication`. On 27.2 that is the only level the API offers: an intent can require authentication, but an entity or a property can't. So the entities carry no content today. With 27.3, titles and dates become `.alwaysAllowed`, and a deferred Summary property on `MeetingEntity` gets `.requiresAuthentication`.
- **Ask:** Siri's Ask goes through the same path as Ask in the app. On the Mac that is `AgentEndpoints.resolve(taskType: .ask)`, so Hybrid routing, `allowsCloud` and Local-only mode all apply. On the iPhone it is `Intelligence.generator()`. Changes the agent proposes are never made from Siri; the answer says to confirm them in LidIA.
- **Follow-ups:** Draft Follow-Up and Prepare Next Step only open sheets in LidIA. Siri hears what was prepared and for whom, never the draft. Nothing is sent until the user chooses Open in Mail, Copy or the confirm button.
- **Spotlight:** the summary is left out of the index while content is blocked, because Siri can read what Spotlight holds.
- **Donations:** a donated Ask carries the question, so it is skipped while content is blocked.

## What switches on with the 27.3 SDK

The 27.2 SDK lacks all of the following:

- `ToolIntent` and `@AppIntent(.tool)`
- `GenerableEntity` and `@AppEntity(.generable)`
- `AppIntentTraits`
- `@Property(description:)`
- property- and entity-level `authenticationPolicy`
- `visibility: .internal`
- skills bundles

I checked the swiftinterface for each. These pieces are staged so that today's build never sees them:

- **Marker comments.** `// siri-27.3:` comments sit next to the code they change, in `Sources/LidIA`, `Packages/LidIAKit/Sources` and `LidIAiOS/{Sources,Shared}`. There are 54 today.
  - A line `// siri-27.3: <code>` is inserted when switched on. Examples: `@AppIntent(.tool)` on every intent, the deferred Summary property with `.requiresAuthentication`, internal properties, entity-level `.alwaysAllowed`.
  - `<code> // siri-27.3: <replacement>` swaps in the replacement. Example: every `@Property(title:)` becomes `@Property(title:description:authenticationPolicy:)`.
- **`Siri/Staged-27.3/`.**
  - `LidIAAppIntents/MeetingSearchRequest.swift`: an `@AppEntity(.generable)` search that Siri fills straight from the request. It becomes Find Meetings' "Search" parameter.
  - `Skills.skillsbundle/Skills/*/SKILL.md`: five skills, `meeting-follow-up`, `prep-for-meeting`, `catch-up`, `action-item-next-step` and `live-meeting`. The iPhone gets the four that don't rely on Mac-only intents.
- **`scripts/siri-27.3.py`:**
  - `status`: what is on, and the markers per file.
  - `check`: validates the skills (folder names, only `SKILL.md`, `name` and `description` frontmatter, body ≤ 10,000 characters, no intent type names), checks that the switched-on code parses (`swiftc -parse`), and probes the SDK.
  - `on`: switches everything on. It refuses unless the SDK probe typechecks.
  - `off`: the exact inverse; `on` then `off` leaves the tree unchanged.

### Switching on (exact steps)

1. Install Xcode 27.3 beta and select it: `sudo xcode-select -s /Applications/Xcode-beta.app`. Install the macOS 27.3 and iOS 27.3 betas on devices that support Apple Intelligence.
2. Run `python3 scripts/siri-27.3.py check`. It must print `Siri AI APIs available` and no problems.
3. Run `python3 scripts/siri-27.3.py on`.
4. Build:
   - `swift build`
   - `swift test`
   - the iOS build command from CLAUDE.md
   - the watchOS build command from CLAUDE.md

   Two things the 27.2 SDK couldn't tell me:
   - **Availability.** If the compiler asks for `@available(macOS 27.3, iOS 27.3, *)` on tool intents, either raise the deployment targets for preview builds or wrap the markers' types as it suggests. The apps deploy to 26.0 today.
   - **Processor arguments.** Build the iOS project once with `-verbose` and compare its `ExtractAppIntentsMetadata` command line with `scripts/lib/appintents-metadata.sh`. If 27.3 added or renamed arguments, mirror them.
5. **Skills on the iPhone.** `on` puts `LidIAiOS/Sources/Skills.skillsbundle` in the app's synchronized `Sources` folder, so Xcode adds it to Copy Bundle Resources. Check that the target shows it, and that the build log has the skills compile step.
6. **Skills on the Mac.** SwiftPM can't compile a skills bundle.
   1. Find the tool and arguments Xcode uses for `Skills.skillsbundle` in the iOS `-verbose` log.
   2. Add that step to `scripts/lib/appintents-metadata.sh`. Use `Siri/Staged-27.3/Skills.skillsbundle` as the input (all five skills) and `LidIA.app/Contents/Resources` as the output, the same pattern as the metadata.
   3. Rebuild with `./run.sh`.
7. Open `LidIAiOS.xcodeproj` and run the **Siri Integration Advisor**. Fix what it flags in titles, descriptions and parameters. For the Mac, open `Package.swift` in Xcode 27.3 and run it on the `LidIA` scheme.
8. Commit. To go back: `python3 scripts/siri-27.3.py off`.

The Siri AI preview runs only on development-signed builds and internal TestFlight. It is not available to external TestFlight or App Store users.

## Testing

### Automated (today)

`swift test` runs `Tests/LidIATests/SiriIntentsTests.swift`, which covers:

- Lookup rules: person, project, keyword ranking, the transcript fallback, inclusive date ranges, people merging, projects, "mine" detection, action item filters and order.
- `SiriContentPolicy`, decisions extraction, the recap with and without content, HTML escaping, spoken text, the Settings search entry, and the "What leaves this Mac" row.
- The intents run against an in-memory library. Get Meeting Summary and the Mail recap carry no summary in Local-only mode or with the setting off. Ask never reaches the host when content is blocked. Find, List, Add, Mark Done and Open work in Local-only mode. Entity queries are tested by id, by words and by suggestions.

These intent tests live in the serialized Local-only suite because they flip the same setting.

`AppIntentsTesting` is in the 27.2 SDK, under `Platforms/MacOSX.platform/Developer/Library/Frameworks`. But it drives a *registered, installed* app through the system. Outside an Xcode test host it can't connect: every run fails with "transport cancelled", for a registered app and an unknown one alike. So it isn't used here. With 27.3, `SiriEvaluations` and `AppIntentsTesting` belong in an Xcode test target that runs against a development-signed build.

### On the Mac today (Shortcuts, Spotlight, classic Siri)

1. Run `./run.sh` and let LidIA launch once.
2. In Shortcuts, search "LidIA". The Mac should list 14 actions.
3. Try these phrases with Siri or Spotlight (they include the app name):
   - "Record a meeting with LidIA" · "Graba una reunión con LidIA"
   - "Add a note in LidIA": it asks "What should I write down?" · "Añade una nota en LidIA"
   - "Bookmark this moment in LidIA" · "Marca este momento en LidIA"
   - "Stop recording in LidIA" · "Deja de grabar en LidIA"
   - "Show my action items in LidIA" · "Muestra mis tareas en LidIA"
   - "Find meetings in LidIA" · "Busca reuniones en LidIA"
   - "Summarize a meeting in LidIA": it asks which meeting, then to authenticate · "Resume una reunión en LidIA"
   - "Ask LidIA about my meetings" · "Pregunta a LidIA sobre mis reuniones"
   - "Draft a follow-up in LidIA" · "Redacta un seguimiento en LidIA"
4. Turn on Local-only mode and ask for a summary again. Siri should give the meeting's title and date and say the notes stay on the Mac.

### With the 27.3 betas (Siri AI)

1. Switch on (above) and install a development-signed build on each device.
2. Bring LidIA to the foreground, or start a recording on the iPhone so its Live Activity is up. Siri then needs no app name:
   - While recording: "Bookmark this", "Note that we agreed on the May pilot", "Add a task for Mateo to send the contract by Friday", "Stop recording".
   - On a meeting page: "Summarize this", "What did they ask me to do here?", "Draft the follow-up" (Mac).
   - On an action item: "Prepare the next step for this" (Mac), "Mark this done".
3. With LidIA in the background, name the app:
   - "What did Mateo ask me to do in LidIA?"
   - "Catch me up on the Northwind project since Monday in LidIA"
   - "Prepare me for my next Northwind meeting with LidIA"
   - "Email the recap of my Northwind meeting to Mateo": Siri finds the meeting in LidIA and hands its recap to Mail. Nothing is sent until you confirm.
   - "¿Qué tareas tengo pendientes en LidIA?"
4. Change the wording of each request to check that the skills' descriptions match it.

### Not verified yet

- Running intents through Siri or Shortcuts end to end on a real device. Today's checks are linkd registration, the generated metadata, and the intents' `perform()` in unit tests.
- Anything on the 27.3 SDK: the staged code parses, but it has never been typechecked.
- Spanish phrases from a build inside `~/Documents` (see above).
- Snippet card rendering inside Siri.
- How Mail receives the HTML recap compared with the plain-text one.
