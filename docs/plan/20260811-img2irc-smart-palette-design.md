# img2irc — Smart Palette Mode (design)

**Date:** 2026-08-11
**Status:** Approved for implementation
**Scope:** `frontend/src/lib/img2irc.ts`, `frontend/src/components/Img2IrcDialog.svelte`, tests

## Goal

Add a `midgardMode='smart'` option to the Colors dropdown that derives **two per-image
palettes** — a truecolor k-means palette (`\x04`) and a smart subset of the fixed 99
mIRC indices (`\x03`) — so the art's color choices are optimal for the image rather
than a fixed palette, while keeping the "renders in any stock client" invariant.

## Problem being solved

- Naive truecolor pays 14B/prefix per color change — 61,260 B (154 messages) on a
  60×60 photo (Aristotle measurement).
- The fixed 16/256 palettes are a poor photographic basis (ΔE ≈ 25–38 on photos).
- The current indexed path picks a *per-row* candidate set `S=12`, which reshuffles
  colors between rows and on every slider drag (flicker) and ignores run-length.
- mIRC indices are semantic — you cannot *remap* what a client renders for index k;
  the only "smart mapping" available for `\x03` is **subset selection** from the fixed
  99 plus cheap-prefix bias.

## Two palettes, derived once per image

```
image → derive Palette A (k-means, K=24, OKLab)  → \x04 truecolor Viterbi
      → derive Palette B (mIRC-99 subset, K≈16)  → \x03 indexed Viterbi
```

Both derivations run once when the image first converts; slider drags reuse them
(stable, no flicker, no per-row reshuffle).

### Palette A — truecolor k-means (K=24)

- Lloyd k-means in OKLab (mean is the optimal centroid — `RequestProject/Clustering.lean`
  `centroid_minimizes`).
- Marginal-stop rule: stop adding centroids when ΔE saved < λ·(run-split cost);
  K≈24 is the measured sweet spot.
- Emission: `\x04 RRGGBB` pair (14B) / fg-only (7B), sticky-state elision, Viterbi
  over 24² ordered states.
- Smart = 24 fixed colors → long runs → the 14B prefix amortizes over runs.

### Palette B — mIRC-99 subset (K≈16)

- Assignment: `min_σ Σ fᵢ·digits(σ i) + λ·Σ fᵢ·ΔE(cᵢ, IRC99[σ i])` over injective
  `σ : Fin K → Fin 99`.
- Greedy frequency-rank is exactly optimal for the prefix term (`PaletteAssignment.lean`
  `greedy_prefix_optimal`); full Hungarian only when ΔE dominates (`greedy_gap_le`
  bounds the gap at λ·ΔEmax·Σf).
- Run-aware guard: restricting to cheap 0–9 indices can *raise* bytes if it breaks
  runs (`OneDigitNonMonotone.lean`) — selection must weigh run-length cost, not just
  distance.
- Emission: existing `\x03` indexed Viterbi, candidate set = Palette B (not per-row S=12).

## UI

- New `<option value="smart">Smart</option>` in Colors dropdown → `midgardMode='smart'`,
  `renderMode='ansi24'` (truecolor path).
- Palette derivation runs once on first convert; drags reuse it.
- `viterbiW` continues to control byte-vs-quality; smartFit ladder unchanged.

## Wire cost expectations (Aristotle data, subject to re-measurement)

| Mode | Photo bytes | Notes |
|---|---|---|
| Naive truecolor | 61,260 (154 msgs) | baseline |
| Smart truecolor K=24 | ~11–13 B/cell | long runs amortize 14B prefixes |
| Indexed smart K=16 | ~5 B/cell | better than fixed-16 on smooth images |

## Open questions for implementation — resolved 2026-08-11

| Question | Resolution |
|---|---|
| Exact K for Palette A (24 vs 16 vs 32) | **K=24, capped to 16 for Viterbi** (Tasks 1 & 5). K=24 gives 24 distinct OKLab centroids on photographic content (24×24 gradient test); Viterbi caps to 16 most-frequent via `rankSmartPaletteA` → 256 states (vs 576) to keep `viterbi_cellGlyph` under 80% of total. Measured via `verify_smart.ts` T1/T5. |
| λ for Palette B subset | **λ=0.02** (Task 2). Greedy `f/(1+λ·digits)` biases to single-digit indices; `greedy_prefix_optimal` → optimal for prefix term, `greedy_gap_le` bounds ΔE gap. Verified: all-red image selects 4/52 (red) within top-16, injective, range 0–98. |
| Whether Palette B needs run-aware selection pass | **Greedy+digit bias suffices** for v1. `OneDigitNonMonotone` guard noted but not wired — Task 6 uses palette B as candidate set, run-length cost handled by Viterbi DP, not pre-filter. Future: add run-aware guard if indexed bytes regress on solid-colour images. |
| Palette derivation timing: reuse across `smartFit` iterations | **Derive once per image in `imageToIrcArt`/`FromBitmap`** (Task 4), guarded by `if(!_smartPaletteA)`. Deterministic seeded k-means (xorshift seeded from pixel hash) ensures stable reuse even on re-derive; dialog passes cached palette via `_smartPaletteB` for worker path. `smartFit` ladder unchanged (indexed path only). |
## Files

- `frontend/src/lib/img2irc.ts` — `smartPalette()` (k-means + subset assignment),
  `\x04` Viterbi over derived palette, `midgardMode='smart'` in `getMidgardPalette`.
- `frontend/src/components/Img2IrcDialog.svelte` — dropdown option, derived-palette
  reuse in `convert()`.
- `frontend/src/lib/img2irc.coverage.test.ts` — k-means, subset selection, run-aware
  guard, Viterbi-emission tests.
