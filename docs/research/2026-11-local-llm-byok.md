# Local LLMs and BYOK for LidIA: recommendation

**Date:** 2026-11-02
**Scope:** Which local models LidIA should offer as downloads, how bring-your-own-key (BYOK) cloud providers should work, and what a new user gets with no setup. This feeds the LLM settings and onboarding redesign.
**Status:** Recommendation. No source code was changed for this document.

Where a claim comes from code in this repo, it cites `file:line`. Web sources are listed at the end with the date each was accessed. Download sizes come from the Hugging Face API (`/api/models/<repo>?blobs=true`), queried on 2026-11-02.

---

## TL;DR

1. **Stop defaulting to Ollama.** On first launch, use **Apple's on-device Foundation Model** when it is available: it needs no download and works immediately. At the same time, offer **one recommended MLX download sized to the Mac's RAM**, which takes over summaries once it is ready. If Apple Intelligence is unavailable, that download becomes the required first step, with "connect a cloud provider" as the secondary option.
2. **Local catalogue: six models instead of five, picked by RAM tier.** It is Gemma 4 plus Qwen 3.5/3.6, all Apache 2.0:
   - 8 GB: Qwen3.5-4B
   - 16 GB: Gemma 4 E4B, the model Google's Foresight app uses
   - 24 GB: Gemma 4 12B
   - 32 GB or more: Gemma 4 26B-A4B

   Phi-4-mini, Gemma 3 4B, Qwen3-8B and Qwen3-30B-A3B-2507 come out of the catalogue.
3. **Semantic search: add a local embedder.** Today retrieval is keyword-only. Ship **Qwen3-Embedding-0.6B (0.35 GB)** now, because the pinned MLX library already supports it. Move to **EmbeddingGemma 2** once `MLXEmbedders` supports it.
4. **Pin `mlx-swift-lm` to the 3.32.3 tag, not `main`.** The pinned commit predates Gemma 4 12B, so 12B **cannot load** today. 3.32.3 also adds `MLXFoundationModels` and `MLXGuidedGeneration`.
5. **`ModelManager` has real bugs:**
   - `isDownloaded` and `deleteModel` look in the wrong cache directory.
   - Downloads are never checksum-verified.
   - Free disk space and RAM are never checked.
   - Download and load are a single step.
   - The model loads into memory at every launch.
6. **BYOK: fewer, clearer providers.**
   - First-class providers: Anthropic (native client), OpenAI, Gemini, OpenRouter, and Apple Private Cloud Compute (macOS 27).
   - One **"OpenAI-compatible"** provider with presets covers Groq, DeepSeek, Cerebras, NVIDIA NIM, LM Studio, Ollama and custom endpoints.
   - Two key tests currently report invalid keys as valid: Anthropic and OpenRouter.
7. **Make data movement visible.** Every provider gets a locality badge. Every summary records where it was produced. LidIA must never fall back silently from local to cloud, which `withProviderFallback` can do today.

---

## 1. What the code does today

| Area | Today | Where |
|---|---|---|
| Default provider | `.ollama`. It is the fallback when nothing is saved, and the wizard only switches to MLX if a model actually loaded | `Settings/LLMSettings.swift:11`, `:112`; `Views/SetupWizardView.swift:338-342` |
| Factory fallback | If MLX is selected without a `ModelManager`, the factory returns `OllamaClient()` | `LLM/OllamaClient.swift:586` |
| Providers | Ollama, LM Studio, MLX, OpenAI, Anthropic, "Cerebras (Free)", DeepSeek, NVIDIA NIM, OpenRouter | `Settings/AppSettings.swift:479-489` |
| MLX catalogue | Qwen3-4B-2507 (default), Phi-4-mini, Qwen3-8B, Gemma 3 4B, Qwen3-30B-A3B-2507 | `LLM/ModelManager.swift:52-93` |
| MLX library | `mlx-swift-lm` `branch: "main"`, resolved to `81829f6` (2026-05-12). Also swift-huggingface 0.9.0 and mlx-swift 0.31.3 | `Package.swift:13`, `Package.resolved` |
| Download | `LLMModelFactory.loadContainer(from: #hubDownloader(), …)` both downloads and loads the model. Progress is reported as a fraction only | `LLM/ModelManager.swift:139-151` |
| "Is downloaded" | Checks `~/Library/Caches/models/<id>` | `LLM/ModelManager.swift:116-119`, `:217` |
| Embeddings | None. Retrieval is keyword and recency scoring | `LLM/MeetingContextRetrievalService.swift:4-46` |
| Apple Foundation Models | Not used anywhere | n/a |
| Keychain | Generic password with service `io.lidia.app`. It deletes and re-adds the item on every `didSet` (every keystroke in a `SecureField`), with no accessibility class | `Settings/SettingsKeychain.swift:9-21`, `Settings/LLMSettings.swift:31-33` |
| Key test | Calls `listModels()` | `Views/Settings/LLMSettingsTab.swift:694-760` |
| iOS | Only an OpenAI key for the realtime voice mode, with its own Keychain helper | `LidIAiOS/Sources/iOSSettings.swift:13,53` |

### Bugs found while reading the code

1. **Wrong cache path.** This app has no `com.apple.security.app-sandbox` entitlement (`Resources/LidIA.entitlements`). For a non-sandboxed macOS app, swift-huggingface 0.9.0 stores downloads in `~/.cache/huggingface/hub/models--<org>--<name>/` (`.build/checkouts/swift-huggingface/Sources/HuggingFace/Shared/CacheLocationProvider.swift:83-90`). `TTSModelManager` already uses that path (`Voice/TTSModelManager.swift:86-90`). `ModelManager` instead checks and deletes `~/Library/Caches/models/<id>`. Likely effects:
   - Downloaded models show as "not downloaded".
   - `warmKeepalive` and `getContainer` never find a model to auto-load.
   - "Delete" frees no disk space.

   This comes from reading the code and has **not been verified at runtime**: no MLX models are present on this machine.
2. **Gemma 4 12B cannot load.** Gemma 4 12B checkpoints declare `Gemma4UnifiedForConditionalGeneration` / `gemma4_unified` (checked against `mlx-community/gemma-4-12B-it-qat-4bit/config.json`). The pinned commit only registers `gemma4` and `gemma4_text` (`.build/checkouts/mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift:34-35`). Gemma 4 12B shipped on 2026-06-03, after the pin. mlx-swift-lm 3.32.3 adds `gemma4_unified`, including a speculative-decoding drafter.
3. **No integrity check.** swift-huggingface has a `computeFileHash` helper (`HubClient+Files.swift:2009`) that nothing calls. Downloaded blobs are never compared with the LFS SHA-256 etag.
4. **The Anthropic key test always passes.** `AnthropicClient.listModels()` catches every error, including 401, and returns a hard-coded list (`LLM/AnthropicClient.swift:68-76`). A wrong key therefore shows as valid. Confirmed: a bogus key gets 401 from `api.anthropic.com/v1/models`.
5. **The OpenRouter key test always passes.** `GET https://openrouter.ai/api/v1/models` returns **200 without any auth** (checked 2026-11-02), so any key "validates". The authenticated check is `GET /api/v1/key`, which returns 401 for a bogus key.
6. **Silent local-to-cloud fallback.** `withProviderFallback` (`LLM/OllamaClient.swift:593-635`) moves to `settings.fallbackProvider` on any error, even when the primary provider is local and the fallback is a cloud provider. That breaks the "local-first" promise without telling the user.
7. **Stale hard-coded cloud model IDs:**
   - `gpt-4o`, `claude-sonnet-4-5-20250514` (`OllamaClient.swift:662-663`)
   - `claude-3-5-haiku-latest`, `gpt-4o-mini` and others (`ModelMenuCatalog.swift:80-99`)
   - the Anthropic fallback list (`AnthropicClient.swift:70-75`)
   - "Cerebras (Free)": Cerebras replaced its always-free tier with a one-time trial in July 2026 [S20].

---

## 2. Local models (MLX on Apple Silicon)

### 2.1 Recommended catalogue

All sizes are the total repo download on Hugging Face as of 2026-11-02. Speeds are decode tokens/sec at a short (~4K) context unless noted. Published Apple Silicon numbers are scarce, especially for M1–M4, and they come from mixed runtimes (mlx-vlm, oMLX, mlx-lm), so treat them as relative.

| RAM tier | Default | Repo | Download | Context (native → **LidIA cap**) | Licence | Published speed |
|---|---|---|---|---|---|---|
| **8 GB** | **Qwen3.5-4B** (reasoning off by default) | `mlx-community/Qwen3.5-4B-4bit` | 3.06 GB | 262K → **16K** | Apache 2.0 [S6] | 99.7 tok/s on M5 Pro, 4.1 GB peak [S8]; 156 tok/s on M5 Max [S7] |
| 8 GB (alt) | Gemma 4 E2B | `mlx-community/gemma-4-e2b-it-4bit` | 3.58 GB | 128K → 16K | Apache 2.0 [S2] | 205 tok/s on M5 Max, 4.7 GB [S7] |
| **16 GB** | **Gemma 4 E4B** (Foresight's model) | `mlx-community/gemma-4-e4b-it-4bit` | 5.18 GB | 128K → **32K** | Apache 2.0 [S2] | 127 tok/s on M5 Max, 6.4 GB at 4K [S7] |
| 16 GB (alt) | Qwen3.5-9B | `mlx-community/Qwen3.5-9B-4bit` | 5.98 GB | 262K → 32K | Apache 2.0 [S6] | ~43 tok/s on M5 MacBook Air (oMLX, with MTP) [S9] |
| **24 GB** | **Gemma 4 12B** | `mlx-community/gemma-4-12B-it-4bit` (+ optional 0.27 GB MTP drafter `gemma-4-12B-it-qat-assistant-4bit`) | 6.77 GB | 256K → **64K** | Apache 2.0 [S3] | No MLX figure published |
| **32 GB+** | **Gemma 4 26B-A4B** (MoE, ~4B active) | `mlx-community/gemma-4-26b-a4b-it-4bit` | 15.37 GB | 256K → **128K** | Apache 2.0 [S2] | 113 tok/s on M5 Max, 17.1 GB [S7] |
| 48 GB+ (alt) | Qwen3.6-35B-A3B | `mlx-community/Qwen3.6-35B-A3B-4bit` | 20.43 GB | 262K → 128K | Apache 2.0 (per mlx-community card) | none found |

**Context caps are a LidIA policy, not a model limit.** KV-cache memory grows with context. A one-hour meeting is roughly 9–10K spoken words, about 12–14K tokens (my estimate at ~150 words/min). The caps above fit a full hour in one pass on 16 GB and up, and they force map-reduce chunking on 8 GB.

**Quality evidence (instruction-tuned, from Google's model cards [S2][S3]):**

| | MMLU-Pro | GPQA Diamond | Tau2 (agentic / tool use) | MRCR v2 128K (long-context recall) |
|---|---|---|---|---|
| Gemma 4 E4B | 69.4 | 58.6 | 42.2 | 25.4 |
| Gemma 4 12B | 77.2 | 78.8 | 69.0 | 43.4 |
| Gemma 4 26B-A4B | 82.6 | 82.3 | 68.2 | 44.1 |

Artificial Analysis ranks Qwen3.5-9B as the most capable model under 10B parameters (index 32) and Qwen3.5-4B as the leader under 5B (index 27). Both still score poorly on its knowledge-hallucination test [S6]. That test measures recall of world facts, not summaries grounded in a transcript, but it supports keeping the "NEVER FABRICATE" prompt rules.

**No public benchmark measures meeting summarisation or action-item extraction for these models.** Before locking in the defaults, LidIA should build a small private eval: 15–20 real transcripts (short, one hour, multilingual) with hand-labelled decisions and action items. Score each tier's default and alternate on action-item recall and precision, and on hallucinated names. Keep the default only if it wins or ties.

### 2.2 Why these defaults

- **Gemma 4 E4B as the 16 GB default:**
  - It matches what Google ships in Foresight [S1], which users and the press will compare against.
  - It is Apache 2.0, unlike Gemma 3's custom terms.
  - It decodes fast because of per-layer embeddings (~4.5B effective parameters).
  - It is pre-trained on 140+ languages, with 35+ supported out of the box [S2]. That matters given LidIA's es/en localisation.
- **Qwen3.5-4B, not E4B, at 8 GB.** The E4B 4-bit repo is 5.2 GB because it carries the vision and audio towers. On an 8 GB Mac that is also running Parakeet, a meeting app and a browser, it is too tight. Qwen3.5-4B is 3.1 GB, leads its size class, and has reasoning off by default [S5].
- **Gemma 4 12B at 24 GB.** It is clearly better than E4B: +8 MMLU-Pro and +27 on Tau2, which matters for chat over meeting history with tools. The 6.8 GB of weights still leaves room on 24 GB.
- **26B-A4B at 32 GB+.** It has only ~4B active parameters, so it decodes nearly as fast as E4B (113 vs 127 tok/s on M5 Max [S7]) with much higher quality. It wins over Qwen3.6-35B-A3B at 32 GB because it is 5 GB smaller.
- **What is dropped and why:**
  - **Phi-4-mini** (2025, MIT): superseded. No Phi-5 was found.
  - **Gemma 3 4B**: superseded by Gemma 4, and it uses the older Gemma terms.
  - **Qwen3-8B**: thinking-by-default wastes tokens.
  - **Qwen3-30B-A3B-2507**: superseded by Qwen3.6-35B-A3B and Gemma 4 26B-A4B.

  Users who already downloaded one of these keep it as "Installed (legacy)". Don't delete their files.
- **Llama / Mistral.** I found no 2026 Llama small model with confirmed availability. "Llama 4 8B" appears only in one unverified blog [S10]. Ministral 3 8B scores below Qwen3.5 on the multimodal benchmark (MMMU-Pro 46% vs 69% for Qwen3.5-9B) [S6]. Neither earns a catalogue slot. Both architectures (`llama`, `mistral3`) still load, for users who add a custom repo ID.
- **QAT variants.** Avoid the `-qat-4bit` repos for now: on mlx-community they are *larger* (E4B QAT is 6.83 GB vs 5.18 GB; 12B QAT is 11.0 GB vs 6.8 GB).
- **Licence metadata.** mlx-community's card for `gemma-4-e4b-it-4bit` still says `license: gemma`, while Google's upstream card says Apache 2.0. The catalogue should show the upstream licence and link to it.

### 2.3 Apple Foundation Models (zero download)

**What it is.** It is `SystemLanguageModel`, the ~3B on-device model behind Apple Intelligence, exposed through the `FoundationModels` framework on macOS/iOS 26+. It is a good zero-setup default for short, structured tasks:
- `@Generable` guided generation gives reliable typed output, such as action items, with no JSON-parsing failures.
- Apple ships three model versions, aligned with OS 26.0–26.3, 26.4 and 27.0 [S14].

**Limits that shape how LidIA uses it:**

| Limit | Detail | Source |
|---|---|---|
| Context window | **4,096 tokens per session on 26.0–26.3**, shared by instructions, prompt, schema and output | TN3193 [S11] |
| Context API | `SystemLanguageModel.contextSize` and `tokenCount(for:)` arrived in 26.4. The WWDC26 sample prints **8192** on OS 27 and Apple says to read the value at runtime | [S12][S13] |
| Over-length input | Throws `exceededContextWindowSize` | [S11] |
| Availability | Needs Apple Intelligence enabled on an eligible Apple Silicon device. The system language must be in `supportedLanguages` | [S14] |
| Guardrails | Can refuse benign content. False positives were reduced in 26.4 and again in 27 | [S12] |
| Fit | Built for summarising, extraction and writing, not world knowledge, maths or code | [S14] |
| Images | Accepted as input on OS 27 | [S12] |

**What that means in practice:**
- A one-hour transcript (~13K tokens) does not fit in one pass, so Apple FM needs **map-reduce chunking**: chunk summaries first, then a merge pass.
- On 4K-context systems, the usable chunk size after instructions and schema is about 2.5K tokens.
- Use Apple FM for:
  - titles
  - action-item extraction per chunk, with `@Generable`
  - short chat answers over pre-retrieved snippets
  - the "summary on first launch, before any download" path

**Apple Private Cloud Compute (PCC), macOS/iOS 27 only** [S12][S13]:
- `PrivateCloudComputeLanguageModel` gives a 32K context with reasoning levels, using the larger model behind Apple Intelligence.
- It needs no account or API key, and Apple states that prompts are not stored.
- It requires an entitlement.
- Developers in the **App Store Small Business Program with under 2M first-time downloads** pay no cloud API costs.
- Users get a daily allowance, which is higher with iCloud+.
- **Open question:** LidIA ships through Sparkle outside the App Store. It is unclear whether the entitlement and the free tier are available to a Developer-ID-distributed app. Check this before building.
- It is still cloud: the transcript leaves the Mac, so it gets the "Apple Private Cloud" badge, not "On this Mac".

**Convergence on OS 27.** OS 27 adds a `LanguageModel` protocol that `SystemLanguageModel`, PCC, and the open-source `MLXLanguageModel` / `CoreAILanguageModel` conform to. Anthropic and Google publish Swift packages for it too [S12]. mlx-swift-lm 3.32.3 ships `MLXFoundationModels` and `MLXGuidedGeneration` [S15].

LidIA's minimum is macOS 26, so **keep `LLMClient` as the abstraction** and add an `AppleFoundationClient` behind it. Adopt the OS 27 `LanguageModel` protocol only when the minimum OS moves to 27.

**Check during implementation:** whether `MLXGuidedGeneration` works without OS 27. If it does, use it to constrain MLX JSON output for summaries, replacing the "Respond ONLY with valid JSON" prompting.

### 2.4 Embedding model for semantic search

**Recommendation:** ship `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` (0.35 GB, Apache 2.0) now. It is a built-in configuration in the pinned `MLXEmbedders` (`.build/checkouts/mlx-swift-lm/Libraries/MLXEmbedders/ModelFactory.swift:73`), so it works with no dependency change.

**Target: EmbeddingGemma 2.** It was released 2026-10-06 [S4] with these properties:
- Apache 2.0.
- A 270M text-and-code core, with optional vision, audio and video towers (740M total).
- 8,192-token input.
- 768-dimension output that can be truncated (Matryoshka) to 512, 256 or 128.
- At 256 dimensions it keeps most of the full-size quality on text.

Foresight uses it [S1].

Two things block it today:
- `MLXEmbedders` only registers EmbeddingGemma **1** (`gemma3`, `gemma3_text` and `gemma3n` model types, `ModelFactory.swift:28-30`). EmbeddingGemma 2 is built on a Gemma 4 decoder.
- The mlx-community conversions bundle every modality: 4-bit is 1.13 GB, 8-bit 1.27 GB, bf16 1.52 GB.

A community Swift runtime (`Nurymanau/EmbeddingGemma-2-MLX-Swift`, ~481 MB q8 text weights) exists [S16], but it is not first-party. Switch when `MLXEmbedders` gains EmbeddingGemma 2 and a text-only 270M conversion is available.

**Design so the switch is cheap:**
- Store `embedderModelID` and `dimension` with every vector, and re-index in the background when they change. A few thousand meetings re-index in minutes.
- Index at the chunk level (about 512-token transcript windows, plus summary and notes), not per meeting.
- Combine vector and keyword scores in `MeetingContextRetrievalService`, keeping the current keyword and recency scoring as one signal.
- Store 256-dimension float16 vectors: 512 bytes per chunk.

The embedder is small enough to stay loaded alongside any LLM tier.

**Fallback with no download:** `NLContextualEmbedding` from the NaturalLanguage framework. Its quality is lower, but it adds no download and is useful on iOS.

---

## 3. iOS (and watchOS)

| Device class | Local LLM | Long-meeting summary |
|---|---|---|
| Any Apple-Intelligence iPhone (iOS 26+) | **Apple FM, the default** (4K context on 26.0–26.3, read `contextSize` on 26.4+) | Chunked Apple FM for a quick summary. The full summary is produced by the Mac when the meeting syncs, or by PCC or BYOK if the user opted in |
| 8 GB iPhones | Optional **Gemma 4 E2B** (3.58 GB) or **Qwen3.5-2B** (1.75 GB). Needs the `com.apple.developer.kernel.increased-memory-limit` entitlement | Foreground only |
| 12 GB iPhones (17 Pro / Pro Max) | Optional **Gemma 4 E4B** (5.18 GB), measured at ~27 tok/s on iPhone 17 Pro [S18] | Foreground only |
| Apple Watch | None. PCC is newly available on watchOS 27 [S12], but route through the phone | n/a |

**Evidence:**
- Gemma 4 E2B runs at ~40 tok/s on a recent iPhone with MLX [S17], and at 30–62 tok/s on iPhone 17 Pro depending on runtime [S18].
- E4B (3.65 GB with LiteRT) loaded on iPhone 17 Pro only once the increased-memory-limit or extended-virtual-addressing entitlement was enabled [S17].
- A Core AI build of E2B peaked at 4.4 GB against a ~6.4 GB entitled limit [S17].

**Recommendation:**
- Don't put the full Mac catalogue on iOS. Offer at most one optional download (E2B, or E4B on 12 GB devices), Wi-Fi only.
- Make the Mac the place where heavy summaries happen. This depends on the CloudKit sync that is currently commented out in `LidIA.entitlements`.
- A 60-minute summary on a phone should never run in the background. Use Apple FM chunking in the foreground, or defer the job.
- **Check during implementation** whether iOS 26's `BGContinuedProcessingTask` grants GPU time on the target devices before promising background summaries.

---

## 4. Download UX and plumbing

### 4.1 What to keep

swift-huggingface 0.9.0 already **resumes downloads**. It writes `<etag>.incomplete` and re-requests with `Range: bytes=<offset>-`, handling 416 and 200-instead-of-206 (`HubClient+Files.swift:586-650`). Blobs are content-addressed by etag, and the repo layout matches the Python cache.

### 4.2 What's missing, and the fix

1. **Separate download from load.**
   - Fetch a snapshot with `HubClient` at a **pinned revision**. `ModelConfiguration(id:revision:)` supports this (`MLXLMCommon/ModelConfiguration.swift:111`).
   - Then load from the local directory.
   - Report bytes done/total, speed and ETA, not just `fractionCompleted`.
2. **One storage location the app owns.**
   - Create `HubClient` with `.fixed(directory: ~/Library/Application Support/LidIA/Models)` on macOS, and with Application Support plus `isExcludedFromBackup` on iOS.
   - Benefits: models are deleted with the app, `isDownloaded` and `delete` can't drift from the downloader again, and Time Machine doesn't back up 15 GB of weights.
   - Migrate existing `~/.cache/huggingface/hub/models--mlx-community--*` folders for catalogue models by moving them, not re-downloading.
3. **Pre-flight checks.**
   - Disk: `URLResourceValues.volumeAvailableCapacityForImportantUsage` must be at least 1.15 × the download size.
   - RAM: compare `ProcessInfo.processInfo.physicalMemory` with the model's `minRAMGB`.
   - Show "Recommended for this Mac", "Will be slow" and "Not enough memory" badges.
   - `ramGB` exists in `ModelSpec` but is only displayed, never enforced (`LLMSettingsTab.swift:135`).
4. **Verify.** After download, hash every LFS file and compare it with its etag, which is the SHA-256 for LFS files (`swift-huggingface/Sources/HuggingFace/Hub/File.swift:43`). On a mismatch, delete the blob and retry once.
5. **Delete properly.**
   - Unload the model, then remove `models--org--name/` entirely, including blobs and refs.
   - Show the space freed.
   - Show a "Storage" row in settings with the total size of models, the embedder, the KV cache (`lidia-kv`, capped at 500 MB) and TTS.
6. **Load lazily and unload when idle.**
   - `warmKeepalive()` puts 3–17 GB of weights in RAM at every launch (`ModelManager.swift:230`). Load on first use instead, or when a recording stops, so the model is warm by the time the transcript is ready.
   - Unload after about 10 minutes idle.
   - On `.critical` memory pressure, unload if nothing is generating. Today it only clears the MLX cache (`ModelManager.swift:290-298`).
7. **Data-driven catalogue.** Replace `availableModels` with a `ModelCatalog` of entries with these fields:
   - `id`, `revision` (a full commit SHA)
   - `displayName`, `family`
   - `downloadBytes`, `minRAMGB`, `contextCap`
   - `license`, `licenseURL`
   - `platforms`, `tier`
   - `promptQuirks` (for example Gemma 4's thinking-channel tokens)

   Keep it **inside the app**, updated through Sparkle releases. A remote catalogue would add a network call users didn't ask for.
8. **Model-specific output handling in `MLXLocalClient`.**
   - `stripThinking` only knows `</think>`. Gemma 4 marks thinking with `<|channel>thought … <channel|>`, while E2B/E4B emit no block when thinking is off [S2].
   - Apply sampling per family. Gemma recommends temp 1.0, top_p 0.95, top_k 64 for chat [S2]. Keep LidIA's low temperature for JSON.
   - Enforce the context cap with token counting, and chunk automatically above it.
9. **No Hugging Face token needed.** Every recommended repo is public and ungated. Gemma 4 is Apache 2.0, with no click-through.

### 4.3 UX

- **Onboarding: one card.**
  > "Summaries on this Mac — Gemma 4 E4B, 5.2 GB, fits your 16 GB Mac. [Download] · Choose another · Use a cloud provider instead"

  Download in the background while the user grants permissions and records a first meeting. Until it finishes, use Apple FM.
- **Settings → Models:** a list with Installed / Download / Recommended badges, the size, licence link, RAM fit, a measured tok/s after the first load (benchmark locally once and store the result), and Delete.

---

## 5. BYOK cloud providers

### 5.1 Provider list

| Provider | Decision | How | Notes |
|---|---|---|---|
| **Anthropic** | **Keep, with the native client** | `AnthropicClient` | Anthropic calls its OpenAI-compatibility layer a testing aid, "not … production-ready", and it drops prompt caching and reasoning output [S19]. Fix the key test (§1, bug 4) and drop the hard-coded fallback list |
| **OpenAI** | Keep | `OpenAIClient` | Pick the default from `/v1/models` using a family preference, not a hard-coded ID. Model names changed several times in 2026 [S21] |
| **Google Gemini** | **Add** | `OpenAIClient` with base URL `https://generativelanguage.googleapis.com/v1beta/openai/` [S22] | **Free-tier prompts may be used to improve Google products and seen by human reviewers; paid tier is not** [S23]. Show this on the key screen. A bad key returns **400, not 401** (checked) |
| **OpenRouter** | Keep | `OpenAIClient` plus a `provider` object in the request body: `{"data_collection":"deny","zdr":true}` by default [S24] | Validate with `GET /api/v1/key`, because `/models` is public (bug 5) |
| **Apple PCC** | **Add on macOS/iOS 27** | `AppleFoundationClient(.privateCloud)` | No key needed. Subject to the eligibility question in §2.3 |
| **Groq** | Preset under OpenAI-compatible | `https://api.groq.com/openai/v1` | Self-serve Zero Data Retention under Data Controls [S25]. Fast, which makes it good for chat |
| **DeepSeek** | Demote to preset | `https://api.deepseek.com/v1` | Point users to its privacy policy for where data is stored |
| **Cerebras** | Demote to preset; **rename** | `https://api.cerebras.ai/v1` | Not free any more: since July 2026 it is a one-time $5 trial that needs a card [S20]. The "(Free)" label is wrong |
| **NVIDIA NIM** | Demote to preset | `https://integrate.api.nvidia.com/v1` | Has no `/models` listing (already special-cased) and is a developer endpoint |
| **LM Studio / Ollama** | **Merge** into "Local server (advanced)" with presets `:1234/v1` and `:11434/v1` | `OpenAIClient` | Ollama added an MLX backend for Apple Silicon in v0.19 (March 2026, labelled preview) [S26]. Keep `OllamaClient` until `/v1` parity (JSON mode, streaming) is tested, then delete it (721 lines) |
| **Custom OpenAI-compatible** | Add | `OpenAIClient` | Base URL, key and model. Covers everything else, including vLLM and self-hosted servers |

**Can one OpenAI-compatible client cover most providers?** Yes. Every provider above except Anthropic and Apple works through `OpenAIClient`, which already handles non-OpenAI hosts (`OpenAIClient.swift:96-110`). It needs three additions:
- an `extraBody` passthrough for OpenRouter's routing preferences
- a per-preset `validationEndpoint`
- per-preset handling of HTTP status codes, because Gemini returns 400 for a bad key

That turns 9 enum cases into **4 client kinds**: `.mlx`, `.appleFoundation(onDevice|privateCloud)`, `.anthropic` and `.openAICompatible(preset)`.

### 5.2 Keychain storage and validation

**Storage:**
- Write the key **when the user commits the field** (on submit, on validate, or when the field loses focus), not in `didSet`. Today every keystroke is a `SecItemDelete` plus `SecItemAdd`.
- Use `SecItemUpdate`, and fall back to `SecItemAdd` on `errSecItemNotFound`.
- Set `kSecUseDataProtectionKeychain: true` on macOS, so the Mac behaves like iOS and avoids legacy-keychain prompts after re-signing.
- Set `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly` by default. Offer an opt-in "Sync keys to my iPhone via iCloud Keychain" (`kSecAttrSynchronizable`). That is how the iOS app gets BYOK without retyping.
- Move the helper into `LidIAKit` so macOS and iOS share one implementation and one set of account names. Today `iOSSettings.swift` has its own.
- Return errors from `save` and show "Couldn't save key" instead of failing silently.

**Validation.** Call one **authenticated** endpoint and map the result to a clear state:

| Result | Shown as |
|---|---|
| 2xx | Valid |
| 401 / 403 (or 400 with an API-key error from Gemini) | Key rejected |
| 402 / 429 | Key valid, but out of credit or rate-limited |
| Network error | Can't reach provider |

Never fall back to a hard-coded list when validating.

| Provider | Validation call |
|---|---|
| OpenAI, Groq, DeepSeek, Cerebras, Gemini-compat | `GET {base}/models` |
| Anthropic | `GET /v1/models`, which returns 401 on a bad key |
| OpenRouter | `GET /api/v1/key`. It also returns the remaining credit, which is worth showing |
| NVIDIA NIM | 1-token `POST /chat/completions` |

### 5.3 Showing when data leaves the device

This is LidIA's main difference from Granola, so it should be visible everywhere, not buried in settings.

1. **A locality badge on every provider and model:**
   - On this Mac (green)
   - Your network server (blue), for local servers whose host is not loopback
   - Apple Private Cloud (purple)
   - Cloud provider, your key (orange)

   For cloud providers, the badge adds the provider's training and retention status, for example "Gemini free tier: may train", "OpenRouter: ZDR enforced", "Groq: ZDR if enabled".
2. **A one-time consent sheet the first time a cloud provider is used.** It lists exactly what is sent (transcript, your notes, attendee names and emails from the calendar, past meeting snippets for chat) and where it goes.
3. **Provenance on every output.** Each summary header reads "Summarised on this Mac · Gemma 4 E4B" or "Summarised by Anthropic · Claude …". Store `generatedByProvider` and `generatedByModel` on `Meeting` (new SwiftData fields).
4. **The chat bar shows the active locality.** A small badge appears next to the input and changes colour when routing goes to the cloud.
5. **No silent fallback across the locality line.** When the primary provider is local and the fallback is cloud, ask: "Local model failed. Send this meeting to OpenRouter instead?" Offer **Once / Always / Never**.
6. **A per-meeting "Keep on this Mac" lock** (and a per-folder one) that blocks cloud routing for that content, including per-task route overrides.
7. **A local AI activity log** in Settings → Privacy, recording each cloud request:
   - time
   - provider and model
   - content types sent
   - input and output tokens

   It is kept locally and can be cleared. The OS 27 `usage` property and OpenAI-style `usage` blocks provide the token counts.

---

## 6. Default on first launch

```
if SystemLanguageModel.default.isAvailable:
    provider = .automaticLocal
    # routes: downloaded MLX model if present, otherwise Apple FM (chunked)
    onboarding: "Summaries work now with Apple Intelligence.
                 For better summaries, download <tier model> (<size>)." → default ON
else:
    onboarding: "Download <tier model> (<size>) to summarise on this Mac" (primary)
                · "Use a cloud provider instead" (secondary, opens the BYOK sheet)
    provider = .mlx once the download finishes; until then AI actions show a
               "Finish setup" prompt instead of an Ollama connection error
```

- The tier comes from `physicalMemory`: under 12 GB gets the 8 GB tier, under 20 GB the 16 GB tier, under 28 GB the 24 GB tier, and above that the 32 GB+ tier.
- **Embedder:** download it with the LLM (0.35 GB). It is too small to ask about separately.
- **Existing users:** keep their saved provider. On launch, if it is `.ollama` and `localhost:11434` refuses the connection, show a non-modal banner: "Ollama isn't running. Switch to on-device summaries?"
- **Never** leave a new user on `.ollama`. Remove `.ollama` as the `loadFromDefaults` fallback, and remove `?? OllamaClient()` from `makeLLMClient`.

---

## 7. Change list (by file)

> Ordering: items marked **P0** are bugs or blockers for the redesign; **P1** is the redesign itself; **P2** can follow.

**`Package.swift`**
- **P0:** Replace `branch: "main"` for `mlx-swift-lm` with `exact: "3.32.3"` (or `.upToNextMinor(from: "3.32.3")`). This unblocks Gemma 4 12B (`gemma4_unified`) and brings in mlx-swift 0.32.3, `MLXFoundationModels` and `MLXGuidedGeneration`.
- **P1:** Add `.product(name: "MLXEmbedders", package: "mlx-swift-lm")`.
- **P2:** Pin `mlx-audio-swift` and `speech-swift` to tags as well. They also track `main`.

**`Sources/LidIA/Settings/AppSettings.swift`** (the `LLMProvider` enum, lines 479-489)
- **P1:** Rework the enum into client kinds: `automaticLocal`, `mlx`, `appleOnDevice`, `applePrivateCloud`, `anthropic`, `openAI`, `gemini`, `openRouter`, `localServer`, `openAICompatible`. Move Groq, DeepSeek, Cerebras and NIM to presets.
- Keep decoding the old raw values ("Cerebras (Free)", "NVIDIA NIM", …) for both `llmProvider` and the `routeOverrides` JSON, and map them to presets.
- Add `var locality: DataLocality` to the provider type.

**`Sources/LidIA/Settings/LLMSettings.swift`**
- **P0:** Change the default `.ollama` (lines 11, 112) to `.automaticLocal`.
- **P1:** Replace the per-provider key, model and URL properties with a `[ProviderProfile]` store, and keep the old Keychain account names for migration.
- **P1:** Stop writing to the Keychain in `didSet`. Expose an explicit `commitAPIKey(_:for:)`.
- **P1:** Add `syncKeysViaICloud`, `allowCloudFallback` (`.ask`/`.always`/`.never`) and `openRouterEnforceZDR` (default `true`).

**`Sources/LidIA/Settings/SettingsKeychain.swift`** → move to `Packages/LidIAKit`
- **P1:** Use `SecItemUpdate` with an add fallback, `kSecUseDataProtectionKeychain`, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with optional `kSecAttrSynchronizable`. Return `OSStatus`/`throws`. Share it with `LidIAiOS/Sources/iOSSettings.swift`.

**`Sources/LidIA/LLM/ModelManager.swift`**
- **P0:** Fix `isDownloaded` and `deleteModel` (lines 116-119, 217) so they use the same cache location as the downloader, and delete the whole `models--org--name` directory.
- **P0:** Stop calling `warmKeepalive()` at launch. Load lazily, unload after idle, and unload on critical memory pressure.
- **P1:** Replace `availableModels` with the data-driven `ModelCatalog` from §2.1, pinned to full revisions and gated by RAM tier. Move the five old models to "legacy" and keep them loadable when they are already on disk.
- **P1:** Use a fixed `HubClient` cache under Application Support, and migrate existing `~/.cache/huggingface/hub` folders.
- **P1:** Make download a separate step from load, with byte-level progress, speed and ETA, disk-space pre-flight, SHA-256 verification against LFS etags, and a resumable "Paused" state.
- **P2:** Record tok/s on first load for display, and to tune context caps.

**`Sources/LidIA/LLM/MLXLocalClient.swift`**
- **P1:** Enforce the per-model context cap with a token count, and chunk with map-reduce above it.
- **P1:** Strip Gemma 4's `<|channel>thought … <channel|>` blocks as well as `</think>` (lines 104-138, 173-185).
- **P1:** Apply sampling parameters per model family.
- **P1:** Inject settings instead of constructing `AppSettings()` inside `getContainer()` (line 154).
- **P2:** Use `MLXGuidedGeneration` for summaries and action items, once confirmed to work on macOS 26.

**New `Sources/LidIA/LLM/AppleFoundationClient.swift`**
- **P1:** Add an `LLMClient` over `SystemLanguageModel`:
  - an availability check (Apple Intelligence off, unsupported language, ineligible device)
  - `contextSize`/`tokenCount` on 26.4+, assuming 4096 below that
  - chunked map-reduce summarisation
  - `@Generable` structs for summaries and action items
- **P2:** Add `PrivateCloudComputeLanguageModel` under `#available(macOS 27, iOS 27, *)`, once the entitlement and eligibility question is answered.

**New `Sources/LidIA/LLM/EmbeddingService.swift` and a vector store** (SwiftData model or SQLite blob table)
- **P1:** Use Qwen3-Embedding-0.6B through `MLXEmbedders` with chunk-level indexing, storing `embedderModelID` and `dimension` per vector, and re-indexing in the background.
- **P2:** Move to EmbeddingGemma 2 (text-only, 256 dimensions) when `MLXEmbedders` supports it.

**`Sources/LidIA/LLM/MeetingContextRetrievalService.swift`**
- **P1:** Score hybrid: vector similarity plus the existing keyword and recency score.

**`Sources/LidIA/LLM/OllamaClient.swift`** (the factory and fallback live here)
- **P0:** Remove `?? OllamaClient()` from `makeLLMClient` (line 586). Fall back to `AppleFoundationClient`, or throw a "finish setup" error.
- **P0:** In `withProviderFallback` (lines 593-635), block or prompt when the fallback crosses from local to cloud.
- **P1:** In `makeClientForProvider` (lines 537-575), add the new kinds and presets.
- **P1:** In `defaultModelForProvider` (lines 657-668), remove the stale cloud IDs and resolve from the fetched model list using a family preference.
- **P2:** Once local-server parity is confirmed, delete the native `OllamaClient` and move `LLMClient` and its shared types to their own file.

**`Sources/LidIA/LLM/OpenAIClient.swift`**
- **P1:** Add an `extraBody: [String: any Sendable]` passthrough for OpenRouter's `provider` object.
- **P1:** Add a per-preset `validate()` with the status mapping in §5.2. Treat Gemini's 400 "API key not valid" as a rejected key.

**`Sources/LidIA/LLM/AnthropicClient.swift`**
- **P0:** `listModels()` (lines 48-77) must rethrow 401/403. Return the static list only for network failures, if at all, and update it to current model IDs.

**`Sources/LidIA/LLM/ModelMenuCatalog.swift`**
- **P1:** Delete the hard-coded `preferredModels` IDs (lines 78-100). Replace them with per-provider family-preference patterns, for example Anthropic `sonnet` > `haiku`, applied to the live `/models` list.

**`Sources/LidIA/LLM/ModelRouter.swift`**
- **P1:** Update `thinkingModel` for the new kinds, and drop the hard-coded `"deepseek-reasoner"`.

**`Sources/LidIA/Views/SetupWizardView.swift`**
- **P1:** Implement the §6 flow: Apple FM availability check, a single tier-sized download card, and a cloud-provider escape hatch. Never finish setup on `.ollama`.

**`Sources/LidIA/Views/Settings/LLMSettingsTab.swift`**
- **P1:** Group providers into "On this Mac", "Apple Private Cloud" and "Cloud — your key", each with a locality badge.
- **P1:** Add a models list (fit, size, licence, tok/s, delete) and a Storage row.
- **P1:** Use the new `validate()` and its states.
- **P1:** Add the fallback-consent setting.

**`Sources/LidIA/Models/Meeting.swift`**
- **P1:** Add optional `generatedByProvider`, `generatedByModel` and `generatedLocality` fields (a lightweight SwiftData migration). Add `keepLocal: Bool`.

**`Sources/LidIA/Views/MeetingDetailView.swift`** and **`ChatBarView.swift`**
- **P1:** Show a provenance line on summaries and a locality badge in the chat bar.

**New `Sources/LidIA/Settings/PrivacyLog.swift`** and a Privacy settings section
- **P2:** Add the local log of cloud requests (time, provider, model, content types, tokens), with a Clear button.

**`Sources/LidIA/Resources/LidIA.entitlements`**
- **P2:** Add the PCC entitlement once eligibility for a Developer-ID app is confirmed.

**`LidIAiOS/`**
- **P1:** Make Apple FM the default.
- **P1:** Use the shared Keychain helper with iCloud Keychain sync of BYOK keys.
- **P2:** Offer an optional E2B download (E4B on 12 GB devices), Wi-Fi only, with the `increased-memory-limit` entitlement. Defer full summaries to the Mac.

**Evaluation (new `Tests/` fixtures or a `scripts/` harness)**
- **P1:** Build the 15–20-transcript summary and action-item eval from §2.1 and run it on each tier's default and alternate before release.

---

## 8. Open questions for the owner

1. **PCC distribution.** Can a Sparkle / Developer-ID app get the PCC entitlement and the Small Business free tier, or does that require the Mac App Store? This decides whether "Apple Private Cloud" ships in P2 or never.
2. **iCloud Keychain sync of API keys:** should it be on or off by default? I recommend off by default with a clear toggle. Turning it on makes iPhone BYOK effortless.
3. **Model storage location:** Application Support (recommended, app-owned) or the shared `~/.cache/huggingface` (shared with Python tools, so no re-download for power users)?

---

## Sources (accessed 2026-11-02)

- [S1] Google AI Edge Foresight launch coverage (announced 2026-10-06): [aiweekly.co](https://aiweekly.co/alerts/google-launches-ai-edge-foresight-a-local-macos-meeting-notes-app-running), [How-To Geek](https://www.howtogeek.com/googles-new-ai-note-taker-doesnt-need-the-cloud/), [explainx.ai](https://explainx.ai/blog/google-ai-edge-foresight-mac-local-meeting-notes-embeddinggemma-2-2026). Google's own post was not retrieved; the claim that it uses Gemma 4 E4B/12B plus EmbeddingGemma 2 is from secondary coverage.
- [S2] Gemma 4 E4B-it model card: https://huggingface.co/google/gemma-4-E4B-it (Apache 2.0, 128K, 4.5B effective, benchmarks, thinking-channel format, sampling). Gemma 4 family launched 2026-04-02: [Wikipedia](https://en.wikipedia.org/wiki/Gemma_(language_model)).
- [S3] Gemma 4 12B model card: https://huggingface.co/google/gemma-4-12B (256K, Apache 2.0, benchmarks vs E4B and 26B-A4B; released 2026-06-03 per [buildfastwithai](https://www.buildfastwithai.com/blogs/gemma-4-12b-guide)).
- [S4] EmbeddingGemma 2 developer guide (2026-10-06): https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/
- [S5] Qwen3.5 small models (2026-03-02; Apache 2.0; 262K; reasoning off by default for 0.8B–9B): [Unsloth docs](https://unsloth.ai/docs/models/qwen3.5.md), [LM Studio](https://lmstudio.ai/models/qwen3.5)
- [S6] Artificial Analysis, "Qwen3.5 small models" (2026-03-05): https://artificialanalysis.ai/articles/qwen3-5-small-models
- [S7] Incept5 Gemma 4 + Qwen 3.5 MLX benchmark (M5 Max 128 GB, MLX 0.31.1, mlx-vlm 0.4.4): https://github.com/Incept5/gemma4-benchmark
- [S8] smartypantsnet mac-benchmarks, Qwen3.5-4B on M5 Pro (2026-10-22): https://huggingface.co/datasets/smartypantsnet/mac-benchmarks
- [S9] Qwen3.5-9B oQ4e MTP card (M5 MacBook Air 32 GB, oMLX): https://huggingface.co/mlx-works/Qwen3.5-9B-oQ4e-mtp
- [S10] Local-LLM roundups (weak sources, used only for "nothing better found"): [Atomic Chat 16 GB guide](https://atomic.chat/blog/guides/best-local-llm-16gb-mac), [insiderllm](https://insiderllm.com/guides/best-local-llms-mac-2026/)
- [S11] Apple TN3193, "Managing the on-device foundation model's context window": https://developer.apple.com/tutorials/data/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window.md
- [S12] WWDC26 "What's new in the Foundation Models framework" (session 241): https://developer.apple.com/videos/play/wwdc2026/241/
- [S13] WWDC26 iOS guide (PCC Small Business terms, LanguageModel protocol, Core AI): https://developer.apple.com/wwdc26/guides/ios/ ; context API introduced in 26.4: [InfoQ](https://infoq.com/news/2026/03/apple-foundation-models-context)
- [S14] `SystemLanguageModel` docs (model versions per OS, `supportedLanguages`): https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel ; use-case limits: [Natasha the Robot](https://www.natashatherobot.com/p/apple-foundation-models)
- [S15] mlx-swift-lm 3.32.3 release notes (dated 30 Sep; adds MLXFoundationModels, MLXGuidedGeneration, Gemma 4 12B MTP): https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3
- [S16] EmbeddingGemma 2 MLX conversions: https://huggingface.co/mlx-community/embeddinggemma-2-bf16 ; community Swift runtime: https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift
- [S17] iOS memory entitlements and Gemma 4 on iPhone: [Zenn](https://zenn.dev/mtfum/articles/ios_memory_entitlements?locale=en), [BigGo (MLX ~40 tok/s)](https://finance.biggo.com/news/411c9374d576b21b), [gemma-4-E2B-CoreAI card](https://huggingface.co/mlboydaisuke/gemma-4-E2B-CoreAI)
- [S18] Loci iPhone 17 Pro speeds (E2B 62 tok/s, E4B 27 tok/s; method is approximate): https://askloci.ai/speed/iphone-17-pro/
- [S19] Anthropic OpenAI SDK compatibility: https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk
- [S20] Cerebras free tier replaced by a trial (July 2026): [morphllm](https://www.morphllm.com/cerebras-pricing), [ianlpaterson](https://ianlpaterson.com/blog/free-llm-api-2026/)
- [S21] OpenAI model lineup churn: [OpenAI GPT-5 mini page (marked deprecated)](https://developers.openai.com/api/docs/models/gpt-5-mini), [cloudzero](https://www.cloudzero.com/blog/openai-pricing/)
- [S22] Gemini OpenAI-compatible endpoint: [morphllm](https://www.morphllm.com/gemini-api-pricing) (base URL); bad-key behaviour checked directly on 2026-11-02
- [S23] Gemini API billing, free vs paid data use: https://ai.google.dev/gemini-api/docs/billing ; [Simon Willison on Gemini terms](https://simonwillison.net/2024/Oct/17/gemini-terms-of-service)
- [S24] OpenRouter Zero Data Retention and `data_collection`: https://openrouter.ai/blog/insights/zero-data-retention/ , https://www.openrouter.ai/docs/guides/features/zdr
- [S25] Groq "Your data": https://console.groq.com/docs/your-data
- [S26] Ollama MLX on Apple Silicon (2026-03-30): https://registry.ollama.ai/blog/mlx
- macOS/iOS 27 public release (2026-09-14): [MacTrast](https://www.mactrast.com/2026/09/apple-announces-27-operating-systems-public-release-date/)
- Repo download sizes, licences and revisions: Hugging Face API `https://huggingface.co/api/models/<repo>?blobs=true`, queried 2026-11-02
