# ADR 0001: Stay native Swift or rewrite cross-platform

- **Status:** Proposed
- **Date:** 2026-11-02
- **Decider:** LidIA owner
- **Scope:** macOS app (`Sources/LidIA`), iOS app (`LidIAiOS`), watchOS app (`LidIAWatch`), shared package (`Packages/LidIAKit`)
- **Related:** [LidIA Revamp: Market & UX Analysis](https://claude.ai/artifact/UD9GaNcyH57qDhREjfe34w), `docs/plans/2026-03-17-core-functionality-audit.md`

## Decision in one paragraph

LidIA stays a native Swift app on every Apple platform. Do not rewrite it in Electron, Tauri, React Native/Expo, Flutter or Kotlin/Compose Multiplatform. Every candidate stack would still need Swift for the parts that make LidIA worth using: system-audio capture, Parakeet/WhisperKit on the Neural Engine, MLX, Apple's on-device models and the watch app. A rewrite would cost months, and those Swift parts would survive it as native modules or sidecar processes. Granola, the Electron reference, already works this way: its Mac bundle ships a Swift sidecar built on FluidAudio, the same library LidIA uses. Where Swift does fall short, each gap has a fix measured in days. The Swift bug-fix work in progress should continue as the long-term codebase. Revisit only on one of the triggers listed at the end.

---

## 1. Context

### 1.1 The question

The owner wants a full revamp: much more polish, local-first AI, and bring-your-own-key (BYOK). They will consider a rewrite in Electron or another cross-platform stack only "if Swift somehow falls short" for covering macOS and iOS. The market and UX analysis from earlier today guessed that LidIA's problems are reliability and UX rather than the language. This ADR tests that guess against the code instead of assuming it.

### 1.2 What the codebase is today

| Area | Size | Notes |
|---|---|---|
| macOS app `Sources/LidIA` | 147 Swift files, ~29.4k lines | Views 9.0k, Voice 3.5k, LLM 3.0k, Integrations 1.9k, Recording 1.3k, Audio 1.2k, STT 1.0k |
| iOS app `LidIAiOS/Sources` | ~2.0k lines | SwiftUI, SwiftData with CloudKit `.automatic` |
| watchOS app `LidIAWatch/Sources` | ~190 lines | SwiftUI, local-only store |
| `Packages/LidIAKit` | ~800 lines | Shared `@Model` types plus a sync client; targets macOS 26, iOS 26, watchOS 11 |
| Dependencies (`Package.swift`) | — | WhisperKit, FluidAudio, mlx-swift-lm, mlx-audio-swift, speech-swift (VAD and enhancement), Sparkle, LidIAKit |

### 1.3 Testing the "it's not the language" hypothesis

The audit (`docs/plans/2026-03-17-core-functionality-audit.md`) and today's code show these top defects:

| Defect | Cause | Would a new stack fix it? |
|---|---|---|
| Mic and system audio mixed before transcription, so who-said-what is lost | Pipeline logic | No. Same logic, different language |
| Notifications lack Join + Record and ad-hoc call association | Missing feature | No |
| Clean clones didn't build (`Packages` was gitignored; fixed in `8982d48`) | Repo hygiene | No |
| Mac, iOS and watch don't share data (see §6.3) | Unfinished sync decision | No. Any stack needs a sync design |
| Shared models duplicated by hand between the Mac app and LidIAKit | Code organisation | No. A JS monorepo has the same failure if the package isn't used |
| Basic `TextEditor` for summary and notes (`MeetingDetailView.swift:103`, `:127`) | SwiftUI choice | **Partly.** Web editors (ProseMirror-style) are more mature. §6.1 has a cheaper fix |

**Result:** the hypothesis holds. One item, rich-text editing, is a real platform weakness. It is local to one screen and has a local fix.

### 1.4 How 2026 competitors are built

| Product | Desktop stack | Mobile | On-device ML | Evidence |
|---|---|---|---|---|
| **Granola** v7.726.2 | Electron 44.4.2 (Chromium 152). Bundle is **674 MB** on disk, of which 503 MB is `Electron Framework.framework` | iOS app; job tags list Swift/SwiftUI | **Swift sidecar** `Resources/granola-diarizer` links CoreML/AVFAudio and embeds FluidAudio (`FluidAudio/AsrManager.swift`, `parakeet-ctc-110m-coreml`) | Installed bundle inspected on this Mac; job post: "Our macOS app (built with Electron)" |
| | 30 native `.node` add-ons: `eventkit`, `tcc`, `keychain`, `ax_meeting_detector`, `macos_mic_apps_with_devices`, `set_prevents_activation`, `docktile`, `mission_control`, `clamshell_state`, `dictation_utils`, … plus a Go helper (`bin/granola`) | | | Same bundle |
| **Google AI Edge Foresight** (launched 2026-10-06) | Mac-only, Apple Silicon only. Google hasn't published the UI stack | None yet | Gemma 4 + EmbeddingGemma 2 (740M) on device; secondary coverage says LiteRT is the runtime. LiteRT-LM's Swift API is in early preview with Metal | Press coverage (sources below) |
| **Anarlog** (ex-Hyprnote → Char; open source, ~9.8k stars, `desktop_v1.4.34` on 2026-10-29) | Tauri 2 + Rust + React | **Expo / React Native**, not Tauri mobile | Swift shims for `FoundationModels` (`plugins/local-llm/swift-lib`) and `SpeechAnalyzer` (`crates/transcribe-speechanalyzer/swift-lib`), plus Swift for notifications, TCC, panels and dictation UI | GitHub `fastrepl/anarlog`, 355 KB of Swift |
| | | **Native SwiftUI watch app** (`apps/watch/apple/AnarlogWatch`) | | Same repo |

**What the competitors show:**

1. The Electron leader runs its on-device speech model in Swift, in a sidecar, on the same library LidIA already uses.
2. The best-funded open-source cross-platform rival ended up with **three UI stacks** (Tauri, Expo, SwiftUI) and still writes Swift for every Apple-only API.
3. Granola needs Electron because it ships Windows (since June 2025) and transcribes in the cloud. LidIA's brief is macOS + iOS, local first. Granola's reason for Electron does not apply to LidIA.
4. Foresight, LidIA's closest local-first rival, is Mac-only and Apple-Silicon-only. Cross-platform reach is not what wins this segment right now.

---

## 2. Decision drivers

1. **On-device ML quality, memory and power.** Local first is the product.
2. **Reliability of capture.** System audio plus mic, all day, without draining the battery.
3. **macOS feel.** Menu bar, floating non-activating panels, Liquid Glass, Spotlight, Calendar.
4. **iOS and watchOS reach** from one team.
5. **Cost and risk** for a team of about one, while Granola and Foresight keep shipping.
6. **Hiring and velocity** if the team grows.

Windows and Linux are **not** in the brief. They are noted where a stack would gain them, but not scored.

---

## 3. Options

| | Option | Shape |
|---|---|---|
| A | **Native Swift (fix, don't rewrite)** | SwiftUI + AppKit on Mac, SwiftUI on iOS and watch, one shared Swift package |
| B | Electron | TypeScript/React UI, Node main process, native add-ons + Swift sidecar for ML. A second stack for iOS |
| C | Tauri 2 | Rust core + web UI in WKWebView; Swift via `swift-rs` for Apple APIs; Tauri mobile or Expo for iOS |
| D | React Native / Expo | RN on iOS, `react-native-macos` (Microsoft) on Mac; Swift native modules |
| E | Flutter | Dart UI drawn by Impeller; Swift plugins over platform channels or FFI |
| F | Kotlin / Compose Multiplatform | Kotlin/Native on iOS; **JVM** Compose Desktop on macOS; Swift wrappers for Swift-only APIs |

---

## 4. Platform-dependency inventory

Each row is something LidIA uses today. Each cell says what it becomes in that stack.

Key: **N** = native, no change · **M** = native module or plugin in Swift/ObjC (or Rust where noted) · **S** = separate sidecar process · **R** = regression (works, but worse) · **X** = impossible in that stack

| Dependency (where in code) | A Swift | B Electron | C Tauri | D RN/Expo | E Flutter | F Compose MP |
|---|---|---|---|---|---|---|
| **System audio** via ScreenCaptureKit (`Audio/SystemAudioCapture.swift`); call detection via CoreAudio + NSWorkspace (`Audio/MeetingDetector.swift`) | N | Partial built-in: since Electron 39 Chromium uses Core Audio taps for `loopback`, one mixed stream. **M** for per-app taps and mic-in-use detection (Granola: `macos_mic_apps_with_devices.node`, `ax_meeting_detector.node`) | M (Rust `cidre`/`coreaudio` or Swift shim) | M | M | M (cinterop works for ObjC/C APIs) |
| Same feature **on iOS** | X for every stack: iOS doesn't let any app capture other apps' audio | X | X | X | X | X |
| **Mic** via AVAudioEngine taps (`Audio/AudioCaptureManager.swift:181`, `:394`) | N | R: `getUserMedia` in the renderer, or M | M | M | M | M |
| **Apple Speech** (`STT/AppleSpeechEngine.swift`, `SFSpeechRecognizer`; `SpeechAnalyzer` on 26) | N | M/S (Swift shim; `SpeechAnalyzer` is Swift-only) | M (Anarlog ships one) | M | M | M, needs an `@objc` Swift wrapper |
| **Parakeet / FluidAudio** on CoreML/ANE (`STT/ParakeetEngine.swift`, `ParakeetBatchProcessor.swift`) | N | **S** (exactly Granola's `granola-diarizer`) | S/M | M | M | S/M |
| **WhisperKit** on CoreML/ANE (`STT/WhisperKitEngine.swift`) | N | S, or **R** by switching to whisper.cpp (Metal GPU; ANE only for the encoder) | S or R (whisper-rs) | M or R | R (FFI whisper.cpp) | S or R |
| **MLX** LLM, STT and TTS (`LLM/MLXLocalClient.swift`, `STT/GraniteSpeechEngine.swift`, `Voice/MLXTTSEngine.swift`) | N | S (Swift/Python process), or **R** by switching to llama.cpp (`node-llama-cpp`): close on Metal, but loses mlx-audio TTS/STT and MLX-first model releases | S or R (`llama-cpp-2`) | S or R | R (FFI llama.cpp) | S or R |
| **Apple Foundation Models** (not yet used; free zero-download default on 26) | N | M/S (Swift-only) | M (Anarlog ships one) | M | M | M via Swift wrapper |
| **SwiftData + CloudKit** (`LidIAApp.swift:153`, `LidIAiOS/Sources/LidIAiOSApp.swift:17`) | N | **R**: SQLite + your own sync server, or a CKSyncEngine native module. Loses free, account-less, end-to-end-private iCloud sync | R | R | R | R |
| **EventKit** calendar + reminders (`Integrations/EventKitManager.swift:31`) | N | M (Granola: `eventkit.node`) | M | M | M | M |
| **Spotlight** CoreSpotlight (`Search/SpotlightIndexer.swift`) | N | M | M | M | M | M |
| **Menu bar** NSStatusItem (`MenuBar/MenuBarController.swift:20`) | N | R: `Tray` + popover window, workable | R: tray plugin | R: limited in `react-native-macos` | R: community `tray_manager` | R: JVM AWT/Compose tray |
| **Floating non-activating panels** NSPanel `.nonactivatingPanel`, `.canJoinAllSpaces` (`Views/FloatingPanel/*`, `MenuBar/MeetingJoinBanner.swift`, `Voice/VoiceOrbPanelController.swift`) | N | M (Granola: `set_prevents_activation.node`) | M (community `tauri-nspanel`) | M | **R** (multi-window is weak) | **R** (JVM windows have no NSPanel semantics) |
| **Liquid Glass**: 32 files use `.glass` / `glassEffect` | N | R: imitation (community `electron-liquid-glass` puts NSGlassEffectView behind HTML; controls stay HTML) | R (same, via vibrancy) | R: partial | R: drawn imitation | R: drawn imitation |
| **watchOS** app (`LidIAWatch`) | N | **X**: separate Swift app | X: separate Swift app (Anarlog does this) | X: separate Swift app | X: separate Swift app | X for UI; Kotlin/Native logic only |
| **Sparkle** updates (`Updates/UpdateController.swift`) | N | N-equivalent (Squirrel.Mac / electron-updater) | N-equivalent (Tauri updater) | M (Sparkle) | M (`auto_updater` wraps Sparkle) | R (Conveyor or custom) |
| **iOS app** | N | **X**: Electron has no iOS; needs a second stack | R: Tauri mobile is young (Anarlog chose Expo instead) | N-equivalent | N-equivalent | N-equivalent (stable since 1.8, May 2025) |

**What the table shows:** no candidate turns any Apple-specific row into "free". In the best case (Electron), the Apple-specific half of LidIA becomes a dozen or more native modules plus one or two Swift sidecars, which is Granola's shape. Every option also keeps a separate Swift codebase for watchOS. Every option also loses SwiftData/CloudKit unless it bridges to it.

---

## 5. Scorecard

Scores run from 1 (worst) to 5 (best). Weights reflect the drivers above. The weighted total is out of 100.

| Criterion (weight) | A Swift | B Electron | C Tauri | D RN/Expo | E Flutter | F Compose MP |
|---|---|---|---|---|---|---|
| iOS + watchOS reach (15) | **5** one language, three apps | 1: no iOS; watch separate | 2: Tauri mobile immature; watch separate | 4: good iOS; watch separate | 4: good iOS; watch separate | 4: good iOS; watch separate |
| On-device ML performance + memory (20) | **5** direct CoreML/ANE, MLX, Foundation Models, zero-copy audio | 3: same Swift via sidecar plus IPC and audio copying, or llama.cpp/whisper.cpp | 3: Rust ML is good on GPU; ANE needs Swift | 3: native modules | 2: FFI, ANE needs plugins | 2: Swift-only APIs need wrappers; on Mac the UI runs in a JVM |
| Battery + idle CPU while recording (10) | **5** one process; ANE path | 2: browser + GPU + renderer helpers (Granola ships 4) plus sidecar | 4: one WKWebView; Rust core | 3: JS runtime + bridge | 3: Impeller redraws | 2: JVM on Mac |
| Binary size, excluding models (5) | 4: tens of MB | 1: Granola is 674 MB | 4: about 10–30 MB | 3 | 3 | 2: bundled JRE |
| macOS feel (15) | 4: best available; SwiftUI rough spots (§6.1) | 3: Granola proves "good enough" with 30 native add-ons | 3 | 2: `react-native-macos` 0.83 trails core 0.87; Microsoft partner project | 2: not AppKit; glass is drawn | 1: JVM look and feel |
| Cost of rewrite vs fix (20) | **5** fix in place | 1 | 1 | 1 | 1 | 1 |
| Hiring + velocity, small team (15) | 3: smaller talent pool; Xcode/MLX toolchain friction | 5: largest pool; hot reload | 3: Rust + TS + Swift = three languages | 4 | 3 | 2 |
| **Weighted total** | **90** | 48 | 52 | 55 | 48 | 39 |

**Sensitivity check.** Set the rewrite-cost weight to 0 and double hiring to 30. Swift then scores 83, against 66 for RN/Expo, 62 for Electron and 60 for Tauri (each rescaled to 100). The ranking holds because the ML, battery, watch and macOS-feel rows don't depend on cost.

**Rough rewrite cost.** About 32k lines across three apps. The hard part (audio, recording, STT, LLM, voice; about 10k lines) would be **re-wrapped, not replaced**. For one developer, a rewrite to today's level of function is plausibly 4–8 months with almost no user-visible gain. Meanwhile Foresight is free and Granola keeps shipping.

---

## 6. Where Swift really falls short today, and the cheapest fix for each

| # | Shortfall | Evidence in this repo | Cheapest fix |
|---|---|---|---|
| 6.1 | **SwiftUI rough edges on macOS**: empty glass capsules on toolbar items, keyboard shortcuts done as zero-frame buttons, and a plain-text `TextEditor` for summary and notes | `CLAUDE.md` conventions; `ContentView.swift:136-147`; `MeetingDetailView.swift:103`, `:127` | Use AppKit wherever SwiftUI is weak, as the panels already do. For notes, first try the macOS 26 `TextEditor` with `AttributedString` rich text. If that falls short, use TextKit 2 `NSTextView` through `NSViewRepresentable`. Last resort: **one** `WKWebView` editor (TipTap/ProseMirror) for that one surface. Use web tech where it wins, not for the whole app |
| 6.2 | **Shared models duplicated** between the Mac app and LidIAKit, kept in step by hand | `Packages/LidIAKit/.../Meeting.swift:13` says *"Mirrors `Sources/LidIA/Models/Meeting.swift`; keep the two in step."* (same for ActionItem, TalkingPoint, TranscriptWord). The Mac app imports LidIAKit only in `Voice/VoicePipeline.swift` | Make the Mac app use LidIAKit's models. Delete `Sources/LidIA/Models/{Meeting,ActionItem,TalkingPoint,TranscriptWord}.swift`. Add a `VersionedSchema` step (`Models/SchemaVersioning.swift` exists) for the new defaults. About 1–2 days. This is a code-organisation issue, not a Swift one |
| 6.3 | **Three apps, three sync stories**: Mac has CloudKit off plus a private HTTP sync client; iOS has CloudKit `.automatic`; watch is local-only with no WatchConnectivity, so it never gets data | `LidIAApp.swift:153`, `Sync/SyncManager.swift:297` (`SyncHTTPClient`) vs `LidIAKit/Sync/SyncClient.swift`; `LidIAiOSApp.swift:17`; `LidIAWatchApp.swift:11` | Choose one path. Recommended: SwiftData + CloudKit private database on all three, after the developer account is ready. Use CKSyncEngine only if you need conflict control. Delete the duplicate HTTP client. Alternatively, freeze iOS and watch (an open decision in the analysis doc). A cross-platform stack would make this **worse**: it would have to build its own sync |
| 6.4 | **Build reproducibility / toolchain drift** | `Package.swift` pins `mlx-swift-lm`, `mlx-audio-swift` and `speech-swift` to `branch: "main"`. `project.yml` still lists SwiftWhisper and `SWIFT_VERSION: "6.0"`; neither matches `Package.swift`. MLX's Metal shaders need full Xcode, not Command Line Tools | Pin those dependencies to revisions or tags. Make `Package.swift` the single source of truth: regenerate or delete the stale `project.yml`/`.xcodeproj`. Add a CI build on a macOS 26 + Xcode 26 runner. About 1 day |
| 6.5 | **Compile times**: one 29k-line executable target with `@Model`/`@Observable` macros and MLX in the graph | `Package.swift`: everything sits in target `LidIA` | Split into SPM modules (`LidIAKit` core → `Audio`, `STT`, `LLM`, `Pipeline`, `UI`) so edits rebuild one module. Add `-Xfrontend -warn-long-function-bodies=200` to find slow SwiftUI bodies. Keep MLX out of the UI module's dependency graph |
| 6.6 | **Concurrency friction** | 35 `@unchecked Sendable` / `nonisolated(unsafe)` sites, e.g. `SystemAudioCapture.swift:21-22` | Turn on Swift 6.2 default MainActor isolation (`defaultIsolation(MainActor.self)`) for the UI module. Keep audio and ML in explicit actors. Audit the 35 sites as part of the reliability phase. No language change needed |
| 6.7 | **Outdated Apple APIs** | `AppleSpeechEngine.swift` uses `SFSpeechRecognizer`; `FoundationModels` isn't used | Move to `SpeechAnalyzer`/`SpeechTranscriber` (one file). Add Apple Foundation Models as the zero-download default LLM. Both are Swift-only, so this is an **advantage** for staying native |
| 6.8 | **No Windows or Linux** | — | Not in scope. If it becomes a requirement, see the triggers in §8. Don't weaken the Mac app now to prepare for it |
| 6.9 | **Smaller hiring pool** than TypeScript | — | Keep module boundaries strict and CLAUDE.md/AGENTS.md up to date so contributors and AI agents work fast. Hire Swift-first. The ML and audio core is the moat, and it is Swift in every option anyway |

---

## 7. Decision

**Choose Option A: stay native Swift on macOS, iOS and watchOS. Reject B–F.**

1. The revamp runs on the existing Swift codebase. The parallel bug-fix sessions are long-term work, not throwaway.
2. `Packages/LidIAKit` becomes the real shared core: models, sync, prompts and pipeline types. The Mac app depends on it (fix 6.2), and all three apps share one sync path (fix 6.3).
3. Use AppKit wherever SwiftUI is weak. Allow one embedded web editor only if the native rich-text options in §6.1 fail.
4. The local AI stack stays Apple-native: FluidAudio/Parakeet and SpeechAnalyzer for speech recognition, MLX and Apple Foundation Models for local LLMs, with BYOK cloud providers behind the existing `LLMClient` protocol.
5. Apply fixes 6.2–6.7 inside the revamp's Phase 0 and Phase 1. Together they are roughly one to two weeks of work, against months for a rewrite.

---

## 8. Consequences

**Good**

- The product keeps its edge: ANE-efficient local transcription, free on-device models, a single process while recording, and a bundle in the tens of megabytes rather than Granola's 674 MB.
- One language covers Mac, iPhone and Watch. Shared models stop drifting once LidIAKit is the only source.
- No rewrite freeze. Reliability fixes ship now, while Foresight's launch window is still open.
- New Apple APIs (SpeechAnalyzer, Foundation Models, Liquid Glass) arrive on day one, without shims.

**Bad, and accepted**

- No Windows or Linux. The market served is Apple users only.
- A smaller hiring pool, and Xcode-only builds for MLX.
- SwiftUI's macOS quirks stay. They are handled with AppKit escape hatches, case by case.
- Deeper Apple lock-in (CloudKit, CoreML). Export to Markdown (`Export/ExportService.swift`) and the MCP server (`Sources/LidiaMCP`) keep user data portable.

**Revisit this ADR if any of these becomes true**

1. **Windows becomes a top-three blocker** for users or revenue. Then build a *separate* Windows client (Electron or Tauri). Share only the sync schema and prompt templates, and keep the Mac app native, as Granola keeps its ML in Swift. Do not move the Mac app onto that stack.
2. The team grows to three or more engineers and most of them are TypeScript-only.
3. Apple restricts a core API (ScreenCaptureKit audio, CoreML access to the ANE) in a way a non-Apple runtime avoids.
4. After fixes 6.1–6.6, a measured UX gap remains that only a web UI closes. Even then, consider embedding WKWebView per surface before a rewrite.

---

## Sources

Accessed 2026-11-02.

- Granola bundle v7.726.2, inspected locally at `/Applications/Granola.app`: Electron 44.4.2 (Chromium 152.0.7977.130); 30 `.node` add-ons; `Resources/granola-diarizer`, an arm64 Swift executable linking CoreML that contains FluidAudio and Parakeet CoreML symbols.
- Granola job post "Product Engineer (Desktop/Electron)": <https://builtin.com/job/electron-engineer-windows/4785320>
- Granola for Windows: <https://www.granola.ai/blog/granola-for-windows-setup-teams-and-zoom-capture-and-what-it-controls>
- Granola iOS engineer listing (Swift/SwiftUI tags): <https://app.welcometothejungle.com/jobs/VptN41j4/company>
- Foresight coverage: <https://www.howtogeek.com/googles-new-ai-note-taker-doesnt-need-the-cloud/>, <https://aiweekly.co/alerts/google-launches-ai-edge-foresight-to-rival-granola-on-mac>, <https://letsdatascience.com/news/google-releases-ai-edge-foresight-an-offline-meeting-compani-638edbca>
- LiteRT-LM Swift API (early preview, Metal): <https://ai.google.dev/edge/litert-lm/swift>
- Anarlog (ex-Hyprnote/Char) repository: <https://github.com/fastrepl/anarlog> (`apps/desktop` Tauri, `apps/mobile` Expo, `apps/watch/apple`, `plugins/local-llm/swift-lib` using `FoundationModels`)
- Electron `desktopCapturer` (Core Audio tap loopback default since v39): <https://www.electronjs.org/docs/latest/api/desktop-capturer>
- Electron release cadence and versions: <https://endoflife.date/electron>
- `electron-liquid-glass` (community): <https://docsearch.algolia.com/mcp/docs/repo/meridius-labs/electron-liquid-glass>
- Tauri 2 mobile plugins (Swift/Kotlin): <https://v2.tauri.app/blog/roadmap-to-tauri-2-0/>
- Compose Multiplatform iOS stable in 1.8.0, May 2025: <https://medium.com/@rushabhprajapati20/compose-multiplatform-for-ios-is-now-stable-bf4e2fc35596>
- KMP vs React Native (react-native-macos version lag): <https://kotlinlang.org/docs/multiplatform/kotlin-multiplatform-react-native.html>
- Swift 6.3 Android SDK (Swift's own cross-platform direction, 2026-03): <https://alternativeto.net/news/2026/3/swift-6-3-introduces-the-first-official-android-sdk-and-improved-c-interoperability>

Scores in §5 are judgements made from this evidence, not benchmarks. Before quoting the battery and memory rows externally, check them with Instruments (Energy and Allocations) during a 60-minute recording.
