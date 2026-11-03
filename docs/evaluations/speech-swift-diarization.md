# speech-swift (SpeechVAD) — Evaluation for LidIA Diarization

**Repo:** https://github.com/soniqo/speech-swift (renamed from ivan-digital/qwen3-asr-swift)
**Date:** 2026-03-14

## Verdict: ADOPT (SpeechVAD module only)

## What It Offers

The `SpeechVAD` module provides:
- **Silero VAD** — voice activity detection (streaming + offline)
- **WeSpeaker** — speaker embeddings for speaker identification
- **Sortformer** — end-to-end neural diarization on Neural Engine
- **DiarizationPipeline** — orchestrated pipeline
- **DER Scoring** — diarization error rate evaluation
- **StreamingVADProcessor** — streaming VAD support

This is significantly more capable than FluidAudio's basic spectral clustering diarization.

## Dependency Compatibility

| Dependency | speech-swift | LidIA (via mlx-swift-lm) | Compatible? |
|---|---|---|---|
| mlx-swift | >= 0.30.0 | >= 0.30.6 | Yes |
| MLX module | Used | Used | Shared |
| MLXNN module | Used | Used | Shared |
| MLXFast | NOT required by SpeechVAD | N/A | No conflict |

**SpeechVAD does NOT require MLXFast** — it only uses MLX and MLXNN, which we already have. Safe to add.

## Integration Plan

1. Add `soniqo/speech-swift` as SPM dependency
2. Depend only on `SpeechVAD` target (skip ASR/TTS modules)
3. Replace FluidAudio's `OfflineDiarizerManager` in `ParakeetBatchProcessor` with `DiarizationPipeline`
4. Keep FluidAudio for Parakeet STT — only swap diarization

## Risks

- **Swift 5.9 toolchain** — repo uses Swift 5.9, we use 6.2. May need Sendable annotations.
- **Maturity** — relatively new repo, may have rough edges
- **Model downloads** — Sortformer and WeSpeaker models need downloading on first use

## Effort: Medium (2-3 days)

## Recommendation

Adopt `SpeechVAD` for diarization. Keep FluidAudio for Parakeet STT. The Sortformer neural diarizer running on Neural Engine should be significantly better than FluidAudio's spectral clustering approach.
