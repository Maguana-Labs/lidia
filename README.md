[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-26+-blue.svg)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)

# LidIA

LidIA records your meetings, writes the notes, and keeps track of what you
promised. It's a native Mac app, with an iPhone companion, and it does all of
it on your Mac by default.

*Named for Lidia Mariana, who loved red.* Red is LidIA's colour because it was hers.

## What it does

- **Records** any call or in-person meeting. Audio is written to disk as it's
  captured, so a crash or a full battery doesn't lose the meeting.
- **Transcribes on your Mac**: Apple Speech, NVIDIA Parakeet or WhisperKit, live
  while you talk and refined after, with your mic and the other side kept apart.
- **Writes the notes**: topics, decisions and next steps, merged with what you
  typed during the meeting, and streamed as they're written.
- **Tracks action items** with owner and deadline, on a list or a board, and
  proposes the next step: a reminder, a ClickUp or Notion task, an n8n flow, a
  follow-up email for you to review.
- **Answers questions** about all your meetings (⌘K), with the meetings it used
  as sources.
- **Prepares you** for the next meeting: what you talked about last time and
  what is still open.
- **Fits into your Mac**: the menu bar shows the next meeting and a live
  recording timer; Apple and Google Calendar; dictation in any app with your
  own vocabulary; a voice assistant; Siri and Shortcuts; and a local MCP server
  so other AI apps can read your meetings.
- **iPhone and Watch**: record on the iPhone with on-device transcription and
  notes, a Live Activity while recording, and the library synced through your
  own iCloud.

## Privacy

- Meetings, audio, transcripts and notes live on your Mac (and in your private
  iCloud database if you turn on sync). There is no LidIA server and no
  telemetry.
- The default AI runs on your Mac: Apple Intelligence or a downloaded MLX
  model. A local server (Ollama, LM Studio) works too.
- A cloud model (Anthropic, OpenAI, OpenAI-compatible) is used only with your
  own API key, only for the tasks you choose, and the app says what leaves the
  Mac. **Local-only mode** blocks every network send of meeting content,
  including AI and iCloud sync.
- API keys are kept in the Keychain. Integrations are off until you turn them
  on, and each one says exactly what it sends.

## Build and run

Requirements: macOS 26 (Tahoe) or later on Apple Silicon, Xcode 26+ (Swift 6.2),
and Xcode's Metal Toolchain for the MLX shaders:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Then:

```bash
git clone https://github.com/Maguana-Labs/lidia.git
cd lidia
./run.sh             # build, package LidIA.app in .build/ and launch it
./run.sh build       # build only
swift build          # compile check
swift test           # run the tests
```

Use `./run.sh`, not `swift run`: macOS only grants microphone, calendar and
notification access to a real `.app` bundle.

The iPhone and Watch apps have their own Xcode projects. A fresh clone builds
them unsigned:

```bash
xcodebuild build -project LidIAiOS/LidIAiOS.xcodeproj -scheme LidIAiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project LidIAWatch/LidIAWatch.xcodeproj -scheme LidIAWatch \
  -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO
```

## Signing

Nothing in the repo names a developer team or certificate.

- **Mac app:** `run.sh` signs with the first "Apple Development" identity in your
  keychain (or `LIDIA_SIGN_IDENTITY`), and falls back to ad-hoc signing if there
  is none. iCloud sync needs an Apple Development identity; see
  [docs/icloud-sync.md](docs/icloud-sync.md).
- **iPhone, Watch and the iCloud provisioning helper:** copy
  `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your
  `DEVELOPMENT_TEAM`. That file is gitignored; `Config/Signing.xcconfig`
  includes it when it's there.
- **Releases:** `scripts/create-release.sh` uses the "Developer ID Application"
  certificate in your keychain; see [docs/release-signing.md](docs/release-signing.md).

## First run

1. Launch LidIA. It works without any API key.
2. Grant microphone access when asked (and calendar access, for the agenda).
3. Pick where AI runs in Settings: Apple Intelligence, a downloaded model
   (Settings › Models), a local server, or a cloud provider with your key.
4. Optional: connect Google Calendar, Notion, n8n, Slack or ClickUp in Settings.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md) (project
structure and conventions). Tests and examples use the made-up people and
companies in [docs/fictional-cast.md](docs/fictional-cast.md); please don't
add real names, meetings or transcripts.

## Architecture

Built with SwiftUI + SwiftData on macOS 26. Key patterns:

- **`@Observable`** for all state classes
- **Actors** for thread-safe network clients (Ollama, OpenAI, Anthropic, Google Calendar)
- **Protocol abstractions** for pluggable STT engines (`STTEngine`) and LLM providers (`LLMClient`)
- **SwiftData** for persistence, **Keychain** for secrets, **UserDefaults** for preferences
- **Local-first** — MLX for on-device LLM inference, Parakeet/WhisperKit for on-device STT

See [CLAUDE.md](CLAUDE.md) for detailed project structure and development guide.

## LLM Providers

| Provider | Type | Best For |
|----------|------|----------|
| **Apple Intelligence** | Local (on-device) | Built in, nothing to download |
| **MLX** | Local (on-device) | Privacy, offline use, free |
| **Ollama, LM Studio** | Local (server) | Larger models, GPU offload |
| **OpenAI** | Cloud | Highest quality, fastest |
| **Anthropic** | Cloud | Claude models |

## STT Engines

| Engine | Type | Notes |
|--------|------|-------|
| **Parakeet** | Local | NVIDIA's streaming ASR, best accuracy |
| **WhisperKit** | Local | OpenAI Whisper on Apple Silicon |
| **Apple Speech** | Local | Built-in, no download needed |

## Dependencies

See [DEPENDENCIES.md](DEPENDENCIES.md) for a full list of dependencies and their licenses.

## Why "LidIA"?

LidIA is named after Lidia Mariana, the creator's mother, who loved red; her
colour is the app's colour. The name also nods to the AI at its core: Lid**IA**.

## License

This project is licensed under the [MIT License](LICENSE).
