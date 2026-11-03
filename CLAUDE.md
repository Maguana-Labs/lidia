# LidIA — Project Context

## What is LidIA?

A native macOS meeting transcription and intelligence app built with SwiftUI + SwiftData. Records meetings (crash-safe audio on disk), transcribes on-device via Parakeet / Apple Speech / WhisperKit, summarizes with Apple Intelligence, a downloaded MLX model, a local server (Ollama, LM Studio) or a cloud provider with the user's own key, and integrates with Apple and Google Calendar, Notion, n8n, Slack and a local MCP server. iOS and watchOS companions share `Packages/LidIAKit`; the Mac and iPhone libraries sync through iCloud (CloudKit, the user's private database; see `docs/icloud-sync.md`).

## Build & Run

```bash
./run.sh             # Build + package .app bundle + launch
./run.sh build       # Build only (creates .build/LidIA.app)
./run.sh clean       # Remove .app bundle
swift build          # Compile check only
swift test           # Run tests
```

**Important:** Always use `./run.sh` instead of `swift run`. The app needs a proper `.app` bundle for macOS TCC permissions (Calendar, Reminders, Microphone, Notifications) to work. `swift run` produces a bare executable that can't request permissions.

**Requirements:** macOS 26 (Tahoe), Xcode 26+, Swift 6.2, and Xcode's Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`); without it MLX's `.metal` shaders fail to compile.

**iOS / watchOS** (iOS is active: on-device SpeechAnalyzer + Apple Foundation Models via `LidIAIntelligence`, a recording Live Activity, two-way sync through lidia-sync; watchOS keeps compiling):

```bash
xcodebuild build -project LidIAiOS/LidIAiOS.xcodeproj -scheme LidIAiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project LidIAWatch/LidIAWatch.xcodeproj -scheme LidIAWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO
```

## Project Structure

```
Sources/LidIA/
├── LidIAApp.swift       # Scenes, model container (LibraryLocation + StoreGuardian), notification routing
├── AppCommands.swift    # App menu commands (New Note, Record/Stop, Export, Search, Ask)
├── ContentView.swift    # NavigationSplitView: sidebar + detail + ⌘K Ask palette
├── Audio/               # Capture, crash-safe per-track PCM writer, finalizer (mic.m4a, system.m4a, audio.m4a)
├── STT/                 # STTEngine + Parakeet, Apple Speech (on-device), WhisperKit, Granite; per-source transcriber
├── Recording/           # RecordingSession, capture/transcription services, launch recovery, post-processing
├── Pipeline/            # MeetingPipeline (refine → summarize → actions), map-reduce chunking, notes merge,
│                        #   regenerate/undo, processing queue + progress, store backup/recovery, library location
├── LLM/                 # LLMClient + Apple Foundation Models, MLX, Ollama, OpenAI-compatible, Anthropic clients;
│                        #   provider info, cloud gate (allowsCloud), ModelManager (catalog, downloads)
├── Privacy/             # Consent reminder and disclosure
├── Integrations/        # EventKit, Google Calendar, Notion, n8n, Slack, ClickUp, MCP inbox importer, PrivacyGate
├── Proactive/           # Unified calendar, pre-meeting prompts, notifications
├── MenuBar/             # Status item + popover, meeting banners
├── Views/               # Sidebar/, MeetingPage/ (document + inspector + live mode), Settings/, palettes, dashboards
├── ViewModels/          # NavigationState, chat, meeting list
├── Models/              # StructuredSummary, templates; re-exports LidIAKit's SwiftData models (SchemaVersioning.swift)
├── Settings/            # AppSettings and per-domain settings, Keychain
├── Sync/                # iCloud sync setup (CloudSyncSetup), self-hosted server sync (SyncManager)
├── Siri/               # Mac App Intents (recording, notes, follow-ups), SiriRouter, MacSiriHost
├── Export/ Import/ Search/ Updates/ Voice/ Utilities/
Sources/LidiaMCP/        # Stdio MCP server: reads the store read-only, writes via the MCP inbox
Packages/LidIAKit/       # THE SwiftData models (LidIASchemaV4: Mac, iPhone, Watch), CloudSync status, server sync engine, LidIAFiles;
                         #   LidIALiveActivity: Live-Activity-shaped menu bar state (Foundation only)
LidIAiOS/ LidIAWatch/    # Companion apps (own Xcode projects)
docs/                    # analysis/, adr/, research/, release-signing.md, icloud-sync.md
```

## UI Architecture

The app follows standard macOS NavigationSplitView conventions:

- **Sidebar** (`Views/Sidebar/`): pinned Now row (live recording or next meeting), Today, Meetings (every status, with a Needs Attention group), Action Items, People, Chats
- **Today**: one agenda merged from Apple and Google calendars, with Record / Join & Record
- **Meeting page** (`MeetingDetailView` + `Views/MeetingPage/`): one document (summary merged with the user's notes, action items, notes) plus an inspector with Transcript (audio playback) and Ask. Live mode while recording; stage stepper after Stop
- **Ask palette** (`AskPaletteView`): ⌘K, answers inline
- **Menu bar**: popover with Now/Today; icon turns red with a timer while recording. Shaped like a Live Activity (see below): the recording panel is the expanded view, and "Zoom call started" drops from the icon
- **Keyboard shortcuts**: app-level ones live in `AppCommands.swift`; meeting-page ⌘1–5 use zero-frame background buttons (not toolbar items, which cause ghost capsules on macOS 26)
- **Settings**: Separate macOS Settings scene, not embedded in main window

## Menu bar Live Activities

The installed SDK (Xcode 27.2, macOS 27.2) marks ActivityKit (`ActivityAttributes`, `Activity`, `ActivityContent`), WidgetKit's `ActivityConfiguration` and `LiveActivityIntent` `@available(macOS, unavailable)`; Apple's docs list them for iOS and iPadOS only, and say Mac menu bar Live Activities come from a paired iPhone. So the menu bar does the same job with AppKit:

- `LidIALiveActivity` (in `Packages/LidIAKit`) holds `RecordingActivityState` and `MeetingDetectedActivityState`, shaped like ActivityKit `ContentState`s (Codable, display-ready, timer as a start date for `Text(timerInterval:pauseTime:)`), plus `ActivityUpdateThrottle` (the last transcript line changes at most every 4 s).
- `MenuBar/RecordingActivityFeed` maps `RecordingSession` to that state once a second; the status item's timer and the panel's `RecordingActivityExpandedView` read it. The floating recording pill stays as it is.
- `MenuBar/MeetingDetectedPrompt` drops "Zoom call started" (Record / Not Now / Never for <App>) from the icon and ends it after 2 minutes or when the app releases the mic. `MeetingDetectionBanner` is only the fallback when the icon can't be seen (menu bar overflow).
- Snapshots: build, copy `LidIA.app` with its bundle ID changed (e.g. `io.lidia.app.menubar-snapshot`, so defaults and library are isolated), re-sign ad hoc, and run its executable with `LIDIA_SNAPSHOT_MENUBAR=<dir>`.

**When an SDK marks ActivityKit available on macOS**, move to a real Live Activity. First re-run the probe: a file that declares an `ActivityAttributes`, calls `Activity.request(attributes:content:)` and `ActivityAuthorizationInfo().areActivitiesEnabled`, and defines a `LiveActivityIntent`, typechecked with `xcrun --sdk macosx swiftc -typecheck -target arm64-apple-macos<ver>`. If it compiles: conform the two states' attributes to `ActivityAttributes`, add a widget extension (SwiftPM can't build `.appex`: a small Xcode project built by `xcodebuild` from run.sh and create-release.sh, embedded in `Contents/PlugIns`, signed inside out with its own entitlements) whose `ActivityConfiguration` reuses the two views, and feed it from `RecordingActivityFeed`.

## Siri and App Intents

Full guide: `docs/siri.md`.

- **Where the code is:**
  - Shared entities, queries, intents, the privacy policy and snippets: `Packages/LidIAKit/Sources/LidIAAppIntents`, an `AppIntentsPackage`.
  - Mac-only intents (recording, notes, Draft Follow-Up, Prepare Next Step): `Sources/LidIA/Siri/`.
  - iPhone: `LidIAiOS/Sources/App/AppIntents.swift`, plus the Live Activity intents in `LidIAiOS/Shared/RecordingActivity.swift`.
  - Each app plugs in a `LidIASiriHost` from its `App.init` path, so intents work before any window exists.
- **Mac metadata:** `swift build` doesn't produce `Metadata.appintents`. `scripts/lib/appintents-metadata.sh` (called by `run.sh` and `create-release.sh`) runs Xcode's processors on Swift Build's const values. Without it macOS sees no intents. `linkd` only indexes an app that is signed with a real identity and has launched once.
- **Privacy:** `SiriContentPolicy` decides what Siri gets.
  - Titles, dates, people, projects and action items always go to Siri.
  - Summaries, notes, transcript and Ask answers go only when Local-only mode is off and "Let Siri read meeting content" (Settings › Privacy) is on.
  - Content-returning intents require authentication. Draft and next-step intents only open confirm sheets.
- **27.3-only code** (`@AppIntent(.tool)`, `.generable`, property descriptions and auth, `visibility`, skills) stays out of the build. It lives in `// siri-27.3:` markers and `Siri/Staged-27.3/`, and `python3 scripts/siri-27.3.py check|on|off` switches it. When you add an intent or a property, add its marker too.

## Architecture Patterns

- **@Observable** for all state classes (AppSettings, RecordingSession, MeetingQueryService, EventKitManager, GoogleCalendarMonitor, ChatBarViewModel)
- **Environment injection** — shared `@Observable` objects are injected at app level. Every scene and every AppKit-hosted view (`NSHostingView`/`NSHostingController` in MenuBar/, FloatingPanel/, Voice/) must inject each type its views read with `@Environment(T.self)`; a missing one crashes at runtime, not at compile time
- **Actors** for thread-safe network clients (OllamaClient, OpenAIClient, AnthropicClient, GoogleCalendarClient, NotionClient, GoogleOAuth)
- **Protocol abstraction** — `LLMClient` protocol with Apple Foundation Models/MLX/Ollama/OpenAI-compatible/Anthropic conformances; `STTEngine` protocol with Apple Speech/WhisperKit/Parakeet conformances; `ChatStream` protocol for streaming chat
- **SwiftData** for persistence. One schema for every app (`LidIASchemaV4` in LidIAKit), CloudKit-compatible, synced with iCloud when the build is signed for it (`LibrarySyncMode`)
- **UserDefaults + Keychain** for settings (non-sensitive in defaults, API keys/secrets in Keychain)
- **didSet persistence** — all AppSettings properties save eagerly via didSet, no manual save() needed

## Key Conventions

- Never delete or overwrite the user's library: recovery moves it aside (`StoreGuardian`), and the store lives at `Application Support/LidIA/LidIA.store` (`LibraryLocation`), not SwiftData's shared default URL
- Regenerate must keep action items the user completed, edited or added (`ActionItem.aiFingerprint`)
- Local-only mode (`settings.localOnlyMode`) must block every network send of meeting content, AI and iCloud sync included
- The schema is append-only and CloudKit-compatible: every attribute defaulted or optional, relationships optional with inverses, no `.unique`, never rename or remove a field (`LidIASchemaTests` enforces it)
- Only the device that made a meeting (`Meeting.originDeviceID`) recovers or processes it automatically
- Swift 6.2 strict concurrency — all sendability requirements must be satisfied
- `@MainActor` on all UI-facing classes
- macOS 26+ APIs — `.buttonStyle(.glass)`, background extension effects
- No storyboards — pure SwiftUI with Info.plist for bundle config
- SPM-only build for macOS (the root .xcodeproj is not needed); iOS and watchOS have their own Xcode projects
- Toolbar items must have content — never wrap content in `if` inside a `ToolbarItem` (causes empty glass capsules on macOS 26). Put the `if` outside the `ToolbarItem` instead
- App-level shortcuts live in `AppCommands.swift`; view-local ones use zero-frame background buttons, not hidden toolbar items
- Fixtures, demo content, prompts' examples, comments and docs use the fictional cast in `docs/fictional-cast.md`: never a real person, customer, meeting or transcript (the repo is public)
- No signing team in tracked files: the Xcode projects read `DEVELOPMENT_TEAM` from `Config/Signing.xcconfig`, which includes the untracked `Config/Local.xcconfig`

## Dependencies

Pinned in `Package.swift`; keep `Package.resolved` committed.

- **mlx-swift-lm** (exact 3.32.3) — local LLMs on Apple Silicon
- **mlx-audio-swift** (pinned revision; later commits need mlx-swift 0.33) — local TTS/STT
- **FluidAudio** — Parakeet streaming STT and diarization
- **WhisperKit** — local Whisper
- **speech-swift** — Granite STT and diarizer
- **Sparkle** — updates (needs a real `SUPublicEDKey`; see `docs/release-signing.md`)

## Common Tasks

- **Add a new setting:** Add property with didSet to AppSettings.swift, load in loadFromDefaults(), add UI in SettingsView.swift
- **Add a new LLM provider:** Prefer an OpenAI-compatible preset. Otherwise create an actor conforming to LLMClient, add a case to the LLMProvider enum with its locality in `LLMProviderInfo.swift`, and update the factory in OllamaClient.swift. Every cloud call must go through `allowsCloud(for:settings:)`
- **Add a new STT engine:** Create class conforming to STTEngine protocol, add case to STTProvider enum
- **Add a new integration:** Create client in Integrations/, check `PrivacyGate` before sending, default auto-send to off, state exactly what is sent on its settings card, and wire it into PostMeetingAutomation
- **Add a stored model field:** Add it to `Packages/LidIAKit/Sources/LidIAKit/Models/` with a default value (or optional), add it to `expectedFields` in `LidIASchemaTests`, bump `LidIASchemaV4.versionIdentifier`, and deploy the CloudKit schema to Production before a release (`docs/icloud-sync.md`)

## Product Vision

- Replacement for Granola app
- Menu bar icon with dropdown: upcoming meetings, join button, liquid glass transparency
- Proactive meeting reminders (5 min before)
- Meeting memory: remember past agreements, surface via Apple Reminders
- Action item creation: ClickUp/Linear tickets, Notion docs
- N8N integration for orchestration
- Window app is a MUST HAVE for querying past meetings

## UI Preferences

- Minimalist design with liquid glass transparency
- Dark mode support (system settings)
- Resizable sidebar
- "Ask anything" search bar for AI queries about meetings
