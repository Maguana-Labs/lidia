# What makes LidIA different (November 2026)

## The market moved this month

- **Google AI Edge Foresight** (free, Mac, offline): meeting notes on EmbeddingGemma 2 + Gemma 4, with a document knowledge base. "Local-first" alone is no longer a moat: Google gives it away.
- **Granola** launched free dictation in any app on 29 October (hold Fn). It runs in the cloud. Granola also does Spaces/folders, follow-up email suggestions and a clean meeting page, and remains the bar for polish.
- **dot+** is iOS-first on Firebase and Gemini (cloud). **Wispr, Monologue, Hex, Paraspeech** are dictation-only.

Nobody combines all four of these. That combination is LidIA's position.

## The four things only LidIA does together

1. **It remembers, and acts on what it remembers, on your Mac.** Foresight takes notes; Granola summarises; neither keeps a working memory of your relationships. LidIA keeps a local graph of people, companies, projects, recurring series, commitments and vocabulary, and uses it unprompted:
   - The prep brief knows this is your sixth Northwind call and what you promised last time.
   - Stale commitments surface on their own.
   - A meeting files itself into the right project.
   - "TAPR" is spelled right because you said it in 40 meetings.

   Semantic memory runs on a small local embedding model (EmbeddingGemma 2 class), never a server.
2. **It closes the loop: from conversation to done.** Every competitor stops at notes. LidIA goes further:
   - It decides locally whether a meeting produced real action items. That's a small, fast decision model (LFM3-1.7B / small Qwen class, ~1 GB) running next to everything else.
   - It extracts the items with owner, deadline and destination.
   - It proposes the action: Reminders, ClickUp, Notion, an n8n flow, or "hand to Claude via MCP".
   - You approve, and it sends. The Kanban board is where that lives. Nothing leaves the Mac without your confirmation, and Local-only mode makes that a guarantee.
3. **It is open.** It ships an MCP server that six AI apps connect to in one click, and an inbox through which those apps can write back, under LidIA's review. Next come **Mods**: user-installable templates, actions and integrations. Granola is a walled garden; Foresight is an experiment.
4. **One voice layer, everywhere, private.**
   - **Dictation in any app** (hold a key, speak, polished text lands where the cursor is). It's on-device (SpeechAnalyzer / Parakeet), and it uses your *personal vocabulary learned from your meetings*. No dictation product can do that, because none of them has your meetings. Granola's dictation is cloud-only.
   - **Talk to LidIA**: the same pipeline answers questions about your meetings out loud. Local voices by default; cloud realtime voices (OpenAI, Grok) with your own key when you want a better voice.

## Principles that keep it from becoming a bloated all-in-one

- **One job per surface**, and the right amount of it. A feature that can't be explained in one sentence on its page doesn't ship.
- **Proactive, never noisy.** Every suggestion says why ("because…"), can be dismissed, and learns from the dismissal.
- **Fast first, perfect after.** Live text refines in place; notes stream as they're written; heavy models run after the moment, not during it.
- **Default local, choose cloud.** A 32 GB Mac runs the whole default stack. Cloud models (Claude Sonnet 5.5, effort ≤ medium) are a per-provider, per-model choice, never a silent fallback.
- **Hybrid, per task.** "Where AI runs" is On this Mac / Hybrid / Cloud. Hybrid keeps quick, private steps (dictation, action items, titles, prep briefs, embeddings, the live transcript) on the Mac and sends long writing (meeting notes, Ask, follow-up drafts) to a cloud model. Each task is a provider + model pair the user can change, one line says what leaves the Mac, Local-only forces everything local, and a failed cloud call reruns on the Mac with a visible note.
- **Your subscription, legitimately.** ChatGPT and SuperGrok plans are used through the vendors' own agents, run as the signed-in user over ACP (Agent Client Protocol) or `codex exec`, never by reading their tokens. Any ACP agent can become a provider. Not Claude Code: Anthropic's terms don't allow claude.ai logins in third-party apps, so Claude stays on an API key.

## Default model stack (32 GB+ Apple Silicon)

| Job | Default | Notes |
|---|---|---|
| Live transcript | Apple SpeechAnalyzer (on-device, built in) or Parakeet streaming | Chosen by WER against Granola on real audio (docs/research/2026-11-live-stt.md) |
| Final transcript + speakers | Parakeet batch + FluidAudio diarization | After the meeting |
| Notes | Benchmark winner (Qwen class) or Apple Intelligence; Claude Sonnet 5.5 with a key | docs/research/2026-11-summary-benchmark.md |
| Decisions / action items / routing | LFM3-1.7B or small Qwen, ~1 GB | Only if it beats the current step on Granola ground truth; check the LFM licence for commercial use |
| Memory / search / correlation | EmbeddingGemma 2 (270M) or Apple NLContextualEmbedding | ~300 MB, Matryoshka 256-d index |
| Voice out | Kokoro-82M / Qwen3-TTS locally; OpenAI/Grok realtime with a key | Later: LFM3-Omni-2B (speech in/out in one 2B model) once it runs on MLX |

## Build order

1. Reliability and polish of the core loop: record → live text → notes → actions (in progress).
2. Projects, Kanban with AI actions, proactive suggestions (in progress).
3. Decision model and local semantic memory.
4. Dictation everywhere with personal vocabulary; voice agent polish.
5. Mods.
6. iPhone and Watch: record in-person meetings, then review and approve actions on the go.
7. Siri (in progress). Apple opened Siri AI to every app on 3 November 2026 (Developer Preview, App Intents). LidIA's meetings, action items, people and projects become entities Siri and Spotlight can find. Its actions become tools Siri can call: record, stop, find meetings, list and complete action items, Ask, draft a follow-up, prepare a next step. App skills guide multi-step requests: follow up on a meeting, prep for the next one, catch up on a project. While the iPhone recording Live Activity is up, "stop recording" works without saying LidIA.
   - Now: everything the 27.2 SDKs support.
   - With Xcode 27.3 beta and the 27.3 OS betas: switch on tool intents, generable entities and the skills bundle (docs/siri.md).
   - Solved: the Mac app builds with SwiftPM, which doesn't generate the App Intents metadata the system reads, so `run.sh` and the release script generate it themselves (`scripts/lib/appintents-metadata.sh`). The system indexed a test build's 14 intents.
   - Customers get it only once Apple opens App Store submissions (spring 2027). Until then it reaches development builds and internal TestFlight testers only. It is not available in the EU on iPhone.
   - Local-only mode gives Siri titles and dates, never meeting content.
8. PII masking before cloud calls (TODO). Mask names, emails and numbers in what goes to a cloud model and restore them in the reply. The hook is `OutboundRedactor.prepare` (Sources/LidIA/LLM/OutboundRedactor.swift), already on every cloud request path and identity today. No UI until it works.
