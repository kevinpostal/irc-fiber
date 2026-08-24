# IRC Fiber — img2irc: Colour Palettes, Glyph Engine & Smart Fit

**Audience:** an AI or engineer who has never seen the codebase.
**Goal:** explain exactly how the current image→IRC-art converter works, then pose the
optimization challenges (with the math) we want solved.

---

## 0. The problem

An image must be rendered as *text art* that travels over IRC. Every rendered line is
one `PRIVMSG`, and IRC imposes a **512-byte line limit** (RFC 2812, inclusive of the
`nick!user@host PRIVMSG target :` prefix — leaving ~400 bytes of payload on a
worst-case envelope). The art must also render correctly in *stock* IRC clients
(HexChat, mIRC, WeeChat, irssi): only ordinary mIRC colour codes, CP437 block glyphs,
spaces, and ASCII characters.

Two levers produce an image:

- **Colours** — the palette and the colour-code spelling (how many bytes per colour
  change).
- **Characters** — the glyph alphabet and cell geometry (how many pixels per glyph,
  and how many bytes per glyph).

The core tension: every cell costs *colour-prefix bytes* (only when the colour state
changes) **plus** *glyph bytes* (always). A 60×60-cell image at 3 bytes/glyph is
10 800 bytes of glyphs *before a single colour code is counted* — 28 messages before
any compression thinking.

---

## 1. Current implementation

### 1.1 The wire cost model (everything hangs off this)

```
cell bytes  = colour-prefix bytes (only when the colour state changes) + glyph bytes
line bytes  = Σ cell bytes        (no trailing \x0f — state dies at the PRIVMSG boundary)
```

| spelling | pair update (fg,bg) | fg-only update |
|---|---|---|
| `\x03 f,b`, both indices one digit (`0`–`9`) | **4 B** | 2 B |
| `\x03 f,b`, mixed | 5 B | 3 B |
| `\x03 f,b`, both two digits (`10`–`98`) | **6 B** | 3 B |
| `\x04 RRGGBB,RRGGBB` (truecolor) | **14 B** | 7 B |
| bare `\x03` — reset to client default | **1 B** | 1 B |

Rules we exploit:

1. **Colours are sticky.** A prefix is only emitted when the state changes.
2. **fg is cheaper to change than bg.** `\x03 f` changes the foreground alone (no
   legal "bg-only" form exists) — so any bg change costs a full pair.
3. **Glyphs are paid every cell.** Cost is a pure function of the Unicode block:
   ASCII = 1 byte, Latin-1 = 2, Block Elements/Braille = 3, sextants/octants = 4.
4. **One cell shows at most 2 colours**, whatever the glyph. So a glyph's value =
   (pixels it covers) × (how well that block 2-colours).

### 1.2 Colour palettes (`frontend/src/lib/img2irc.ts`)

Five palettes are compiled in, all as packed `0xRRGGBB` numbers:

| palette | entries | source |
|---|---|---|
| `IRC99` | 99 (indices 0–98) | mIRC palette: 16 classic + extended ramp + 11-grey ramp |
| `ANSI256` | 256 | xterm-256 cube (16 + 6³ cube + 24 greys) |
| `ANSI16` | 16 | ANSI/VGA 16 (`[0,0,0]..[255,255,255]`, 170/85/255 steps) |
| `VGA256` | 256 | Midgard `buildVGA256()`: CGA16 + 16 greys + 6³ cube `[0,51,102,153,204,255]` + 8 greys |
| `XTERM256` | 256 | Midgard `buildXterm256()`: ANSI16 + 6³ cube `[0,95,135,175,215,255]` + 24 greys |

Selection is by the **Midgard Colors selector** (`midgardMode`), matching
`https://midgardmud.de/tools/ans/`:

```
getMidgardPalette(o):
  midgardMode 'vga256'   → VGA256
  midgardMode 'xterm256' → XTERM256
  midgardMode '16'|'retro' → ANSI16
  renderMode 'ansi'      → ANSI256
  else                   → IRC99
```

The mIRC 99-index palette is the stock-client target: only 10 indices (`0`–`9`) are
one digit, so **confining the picture to single-digit indices saves exactly 2 bytes
per colour change** — but indices 0–9 are saturated primaries, a poor photographic
basis (measured ΔE ≈ 38 on the photo test image). mIRC indices are *semantic* — you
cannot remap what a client renders for index k — so palette "compaction" is an
assignment problem, not a remapping problem (challenge §2.1).

### 1.3 Colour matching

Three distance functions, selectable via `colorMatching`:

- `rgb` — squared Euclidean in sRGB.
- `lab` — squared Euclidean in CIE L\*a\*b\* (D65).
- `oklab` — squared Euclidean in OKLab (Björn Ottosson), **scaled ×85 000** to bring
  the distance onto the Lab scale so the byte-weight term in the DP is comparable
  (median Lab/OKLab ratio ≈ 86k; un-scaled OKLab made the Viterbi collapse to
  over-compression).

`kNearest(r,g,b,pal,k,ng,mode)` returns the k closest palette entries under the chosen
metric (skipping near-grey entries for colourful pixels when `nograyscale` is on). A
`COLOR_LUT` map caches lookups per `(r,g,b,mode,ng)`; it is cleared when it exceeds
8000 entries.

### 1.4 Glyph alphabet (`GLYPHS`)

Glyphs are stored with **measured DejaVu Sans Mono ink coverage** per half-cell
(`ct` = top coverage, `cb` = bottom coverage) — a glyph of coverage `c` shows the
blend `c·fg + (1−c)·bg`:

| glyph | bytes | top ct | bottom cb | role |
|---|---|---|---|---|
| `' '` | 1 | 0.000 | 0.000 | solid → space (1 B vs `█` 3 B, bg sticky) |
| `'='` | 1 | 0.122 | 0.120 | ASCII shade |
| `'Q'` | 1 | 0.247 | 0.261 | ASCII shade |
| `'B'` | 1 | 0.294 | 0.253 | densest **safe** ASCII (0.273) |
| `'*'` | 1 | 0.183 | 0.010 | 1-byte "light ▀" |
| `'g'` | 1 | 0.149 | 0.321 | 1-byte "light ▄" |
| `'F'` | 1 | 0.245 | 0.107 | 1-byte "light ▀" variant |
| `▀` | 3 | 1.000 | 0.000 | half block (top=fg, bottom=bg) |
| `▄` | 3 | 0.000 | 1.000 | complement of ▀ |
| `▒` | 3 | 0.490 | 0.499 | mid-tone gap filler |
| `░` | 3 | 0.183 | 0.181 | dominated (1-byte `=`/`Q` beat it) |
| `▓` | 3 | 0.796 | 0.816 | dominated |
| `█` | 3 | 1.000 | 1.000 | **never chosen** — `' '`+bg is same pixels for 1 B |

The ASCII ramp covers 55% of the blend range at **1 byte per glyph** where `░▒▓` cost
3. The **midtone gap**: the densest safe ASCII glyph covers 0.273, so the
`[0.273, 0.727]` band needs a 3-byte glyph — `▒` (0.494) is the workhorse there.
Digits and `,` are excluded (they'd be eaten by 1-digit colour codes); no leading `/`.

Per-cell, for a given state `(fg,bg)`, `bestGlyphForState` picks the glyph minimising:

```
cost = ΔE(top, ct·fg + (1−ct)·bg) + ΔE(bottom, cb·fg + (1−cb)·bg) + w·bytes(glyph)
```

where `w` is the byte-weight (`viterbiW`, default 2.5, knee at 2–4). Swapped
orientation (`fg`↔`bg`) is free — the DP state is the *ordered* pair.

### 1.5 Cell geometries (`pixelMode`)

| geometry | sub-pixels | glyph bytes | B/sub-pixel | notes |
|---|---|---|---|---|
| `full` | 1×1 | 3 | 3.0 | single pixel, `█` |
| `half` | 1×2 | 3 (or 1 with ASCII) | 1.5 (0.5) | default; ▀/▄ plus the 1-B alphabet |
| `quarter` | 2×2 | 3 | 0.75 | 16 quarter-block glyphs; font-dependent |
| `braille` | 2×4 | 3 | 0.375 | 256 dot patterns; font-dependent (dot gaps) |

The 1-byte half-block cell (0.5 B/sub-pixel) is the practical sweet spot for stock
clients. Quarter and Braille are offered but carry font-support caveats.

### 1.6 The Viterbi encoder (half mode, indexed)

Per row:

1. Build a **candidate palette `S`** of up to 12 colours (frequency of the k=2
   nearest matches per half-pixel over the row).
2. States = `S × S` ordered `(fg,bg)` pairs (≤144).
3. Per cell, per state: precompute the best glyph (1.4).
4. Run the sequence DP with **predecessor-independent collapsed transitions**:

```
dp[i][(f,b)] = min over prev of:
    stay same state            dp[i−1][(f,b)]                       (0 bytes)
    fg-only change from any (·,b)  bMin[b] + w·fgPref(f)   = w·(1+|f|)
    full pair change from any      gMin  + w·pairPref(f,b) = w·(2+|f|+|b|)
  + node cost (glyph err + w·glyph bytes)
```

Because the transition cost does not depend on the predecessor beyond
"unchanged / bg unchanged / changed", the inner minimum collapses to a global minimum
plus one minimum per background value — **O(M·K)** with K = |S|², not O(M·K²).

5. Emission: `\x03 f` when only fg moves, `\x03 f,b` otherwise; solid cells become
   `' '` with bg set (never `█`); lines right-trim trailing spaces and carry **no**
   trailing `\x0f`.

Measured on the synthetic test images (photo / landscape, 60×60 cells):

| encoder | photo B (msgs) | landscape B (msgs) |
|---|---|---|
| naive truecolor (`\x04` every cell) | 61 260 (154) | — |
| greedy `▀█` + prefix elision | 17 810 (45) | 16 404 (42) |
| Viterbi `▀█␣░▒▓` + fg-only, w=4 | 11 161 (28) | 6 315 (16) |
| Viterbi `▀█␣` + measured ASCII ramp, w=4 | 8 031 (21) | 4 954 (13) |
| `0..9` ASCII-only, w=4 | 6 476 (17) | 4 296 (11) |

### 1.7 Smart fit (under-512 auto-adjust)

`smartFit()` in `Img2IrcDialog.svelte` iteratively converts and measures the longest
line against `IRC_HARD_LIMIT = 512`, walking a **quality-preserving ladder** — each
step re-renders and re-measures until it fits or no lever remains:

1. **bump `viterbiW` 2.5 → 6** (indexed modes only) — more ΔE-per-byte tradeoff;
   smallest visual damage.
2. **shrink `width` by 4 → `MIN_IRC_WIDTH`** — fewer columns ≈ linear byte cut.
3. **enable Comic** (2× bilateral pre-filter, r=2 σ=40) — edge-preserving smoother
   lengthens colour runs, −11% on smooth sources; only for indexed modes.
4. **truecolor/256 → 16 colours** (`midgardMode='16'`) — biggest byte lever
   (14 B `\x04` pair → 4–6 B `\x03` pair), biggest quality hit; last resort.
5. **min width** — final squeeze. Stop when no lever remains.

Concurrency: a `fitting` flag pauses the debounced auto-convert effect so the fit
loop's direct `await convert()` owns the generation counter; user input mid-fit is
absorbed by the next iteration.

A budget bar shows `{longest} / 512 ({400} safe)` with a green/amber fill and a
⚡ Fit button when over budget.

---

## 2. Challenges for the AI

### 2.1 Optimal palette assignment (the Hungarian problem)

**Context.** mIRC indices are semantic; you cannot remap what a client renders for
index k. "Palette compaction" is therefore: choose an **injective map σ** from K
per-image cluster centroids to mIRC indices, minimising

```
Σᵢ fᵢ · digits(σ(i))  +  λ · Σᵢ fᵢ · ΔE₀₀(cᵢ, palette(σ(i)))
```

with fᵢ the usage frequency of centroid cᵢ, `digits` = 1 for indices 0–9 else 2.

**Solve exactly** with the Hungarian algorithm on a K×99 cost matrix. Expected
prefix length = 1 + Σ pᵢ·digits(i); getting the top-10 colours into single digits
typically saves 0.8–1.6 B on every prefix.

**Open sub-questions:**

- The measured non-monotonicity: restricting to `0..9` *raised* bytes on one test
  image (5 642 vs 4 945 B) because worse matches forced more glyph/colour switches.
  Formalize when cheap prefixes pay for themselves.
- Is a greedy frequency-rank assignment near-optimal, or is the full Hungarian
  worth it? What K? (16 is the measured sweet spot on the photo: −12% bytes for
  +7 ΔE.)
- **Synthesised colours:** blend two 1-digit colours with `░▒▓`/ASCII ramp levels —
  10 tones for a 2–3 B prefix. Model this as: choose base pairs (0..9)² and levels
  to cover the palette with min total prefix+glyph cost. This is a covering
  problem with a 2-hop colour graph.

### 2.2 Optimal glyph alphabet (coverage knapsack)

**Context.** A glyph of coverage c renders blend `c·fg+(1−c)·bg`; with the ordered
(fg,bg) state, coverage `1−c` is free. Colour error = |Δcoverage|·|fg−bg|. Byte cost
is 1 (ASCII) or 3 (block).

**Problem.** Choose a glyph alphabet A minimising, over all possible blends on the
[0,1] coverage axis, the worst-case (or expected) quantisation error at a given byte
budget:

```
min_A  Σ blends  err(blend, A)   s.t.   Σ_{g∈A} bytes(g) ≤ B
err(blend, A) = min_{g∈A, orient∈{g, ḡ}} |coverage(g) − blend| · |fg−bg|
```

Constraints: no digits/`,` (eaten by colour codes), no leading `/` (client command),
`%`/`$` avoided (scripting sigils), and coverage is **font-dependent** (±few %).

**Open sub-questions:**

- Prove the observed midtone-gap bound: densest *safe* ASCII = 0.273 ⇒ any alphabet
  of only ASCII has a gap of ≥ 0.227 → visible error on high-contrast cells. Give
  the optimal ASCII+`▒` mix as a function of the contrast distribution.
- Which measured coverage set is Pareto-optimal? We currently carry 13 glyphs; the
  measurement says `░▓█` are dominated — confirm formally.
- Robust alphabet under coverage uncertainty: minimax over fonts, given measured
  per-font coverage variance.

### 2.3 Mixed-cell geometry (region segmentation)

**Context.** Geometry choice is per-image today, but the data says the best result
mixes per region: **space** for flat areas (1 B/cell), **half-blocks** for colour
ramps, **Braille** for high-frequency detail/edges/text (0.375 B/sub-pixel, 8 dots),
**quarter** for 2×2 structure.

**Problem.** Given a pixel grid, partition it into connected regions and assign each
region a (geometry, palette) pair minimising total wire bytes + λ·ΔE:

```
min_{partition, geometry per region}  Σ_regions [ glyph_bill(geometry) + prefix_bill(palette) + λ·ΔE(region) ]
```

with constraints: cell alignment (regions must tile on the geometry's cell grid),
and stock-client compatibility (Braille needs a font check; quarter blocks are
proportional in some fonts).

**Open sub-questions:**

- The luminance-gap split: for k pixels in a cell, split into bright/dark groups at
  the largest luminance gap, average each group. Prove this is optimal for 2-colour
  cells under what error metric? (This is how Braille/quarter cells choose their
  two colours today.)
- Adaptive column width: rows could carry different widths (trailing-trim already
  exploits this). Model row-wise width selection as a 1-D segmentation.
- Is the row-wise optimum globally optimal, or is there exploitable **vertical
  redundancy** (inter-line diffs measured at 78–86% saving)?

### 2.4 Rate–distortion DP over the whole stream

**Context.** The current Viterbi is per-row. The reference studies prove the λ-sweep
is monotone (raising λ never increases bytes, never improves error) and every
λ-optimum is Pareto-optimal — so **bisection on λ to hit a target message count is
sound**.

**Problem.** Extend to a *stream* DP that also decides:

- **Row packing:** a frontend can pack ⌊C/L⌋ rows per PRIVMSG with a sentinel;
  60 rows of 130 B → 20 messages. This is pure envelope saving, orthogonal to
  compression. Optimize row order/packing given a per-line budget.
- **Inter-line diffs:** encode row i as a sparse change list vs row i−1; bitmask
  beats sparse lists from 5 changed cells/row (measured 78–86%).
- **Where to break a too-long line:** the continuation re-primes colour state
  (~4–6 B); prefer break points with cheap active state and inside long solid runs.

**Open sub-questions:**

- Prove the bitmask-vs-sparse crossover (5 changed cells at M=60) and generalise to
  any M and any palette.
- Formulate the joint (row-pack, inter-line-diff, λ) optimization and give the DP or
  a greedy with a bounded suboptimality gap.

### 2.5 Perceptual quantization

**Context.** OKLab squared distance is an inner-product norm ⇒ segment mean is the
optimal representative, segment cost is `Σ‖xᵢ‖² − n‖mean‖²` (two prefix sums, O(1)
per segment, O(M²) segmentation DP, *exactly* optimal — no candidate list). k-means
in OKLab is well-founded (Lloyd's centroid step is the minimiser).

**Problems.**

1. **k-means with prefix cost:** choose K centroids and their mIRC indices jointly,
   minimising `Σ d²(pixel, centroid) + λ·(prefix cost of centroid index)`. The
   index cost couples the two — solve the alternating minimization (Lloyd step vs
   Hungarian step) and give the fixed-point / convergence argument.
2. **α-aware OKLab:** current code blends RGB linearly for shade glyphs; the
   perceptual mid-point of two colours in OKLab is *not* the 50% RGB blend. Compute
   the true OKLab midpoints for the `░▒▓`/ASCII ramp levels and measure the ΔE
   improvement — this directly biases every shade choice in the Viterbi.
3. **Redmean vs OKLab:** Midgard uses weighted-RGB "redmean"; we use OKLab. Give
   the error/complexity frontier: where does redmean suffice (pre-filtering) and
   where must OKLab be used (DP candidate search)?

### 2.6 Compression & framing (frontend-only path)

**Context.** The compressed wrapper subsumes everything: zlib 91.2%/94.0%, lzma
91.7%/94.1%, bz2 92.9%/95.2% on the test images (101 → 8–9 messages). A 400-byte
message is too small for LZ77 to warm up, so *preset dictionaries* trained on the
art corpus are the lever for per-message independence.

**Problems.**

- **Preset dictionary design:** pick the dictionary maximizing per-message
  compression (offline corpus → dictionary via suffix-array/LZ77 statistics), with
  the constraint that each message decodes independently (composes with erasure
  coding + out-of-order delivery).
- **Base94 framing:** 94 printable ASCII minus space; 9 binary bytes fit in 11
  characters *optimally* (proved), strictly better than base64's 12 (+8.9% payload).
  Generalize: optimal block size for framing into N printable symbols.
- **Erasure coding:** tolerating r dropped messages costs ≥ r extra messages
  (Singleton bound); RaptorQ achieves k+ε in practice. Design the header/framing so
  any k of n messages reconstruct, with the overhead budgeted against measured loss.

### 2.7 Performance (the reason for WASM)

The Viterbi is O(M·K) per row with K = |S|² = 144 states — 120 columns ⇒ ~17k
state-transitions per row, ~120 rows, plus per-cell glyph search over 13 glyphs with
perceptual distance. The bilateral filter is O(W·H·r²). A Rust `wasm32-unknown-unknown`
crate already compiles (`wasm-img2irc`, bilateral_filter implemented, 39 KB); the
integration that previously broke the build was a *static* import of the generated
glue — it must be a **dynamic import with try/catch fallback to JS** so the build can
never fail.

**Problems.**

- Port the Viterbi + kNearest + OKLab/Lab matching to Rust/WASM with the same
  numeric results (bit-exact or within 1 ULP) and benchmark vs the JS baseline.
- SIMD: the nearest-neighbour scan over 99/256 palette entries is embarrassingly
  parallel; the bilateral filter too. Measure the speedup on a 120×120 image.
- Off-main-thread: worker + transferable `ArrayBuffer` (no copy) for the pixel data.

---

## 3. Math we want solved (formal statements)

1. **Hungarian palette assignment.** Given frequencies fᵢ and Lab centroids cᵢ,
   solve `min_σ Σ fᵢ·digits(σ(i)) + λ·Σ fᵢ·ΔE₀₀(cᵢ, pal(σ(i)))` exactly; bound the
   gap of the greedy frequency-rank heuristic. Empirically: what λ makes the
   one-digit trick *not* backfire (the 5 642 vs 4 945 non-monotonicity)?

2. **Glyph coverage knapsack.** For byte budget B and per-glyph measured coverage,
   find the alphabet minimizing worst-case/expected blend error, with the safe-glyph
   constraint set. Prove the midtone-gap bound and the optimal ASCII+`▒` mix.

3. **Mixed-geometry tiling.** Prove the luminance-gap 2-colour split is optimal for
   Braille/quarter cells under squared-Lab error, and design the region-segmentation
   DP (geometry × palette × λ) with the exact complexity.

4. **Inter-line diff crossover.** Prove the bitmask-vs-sparse-list crossover at
   `ceil(M·p)` changed cells for row width M, and the expected saving under a
   geometric change model.

5. **OKLab k-means + index cost.** Convergence of the alternating (Lloyd/Hungarian)
   minimization; the optimal K as a function of the wire-cost parameters.

6. **Base94 optimality.** For a payload of C printable chars and 94 symbols, the
   optimal bytes-per-block and its information-theoretic tightness (we know 9→11 is
   optimal; prove it and the +8.9% payload claim).

7. **λ-sweep bisection.** Already proved monotone (LambdaPareto.lean); make it
   practical: the mapping from λ to message count under row-packing, and the
   bisection convergence rate to a target message budget.

---

## 4. Where the code lives

| File | Contents |
|---|---|
| `frontend/src/lib/img2irc.ts` | Palettes, `GLYPHS`, matching (rgb/lab/oklab), Viterbi, `imageToIrcArt`, `estimateLineLengths` |
| `frontend/src/components/Img2IrcDialog.svelte` | Midgard Colors selector, pixel mode, advanced controls, **smartFit**, budget bar, send pacing |
| `frontend/src/lib/img2irc.test.ts` | Palette sanity + line-length tests |
| `reference/` (Aristotle study, `/Users/zodiac/Downloads/output-final_aristotle 2`) | `colors_chars.py`, `study_improvements.py`, `glyph_coverage.py`, `mirc_compress.py` + results — the measured numbers above |
| `frontend/wasm-img2irc/` (unused, optional) | Rust WASM crate: `bilateral_filter` compiled; Viterbi port is the open work |

All measured byte/ΔE figures are simulations on two synthetic 60×60 images (photo-like
gradient+grain, and landscape sky-over-hills); the 16 classic mIRC colours are exact,
indices 16–98 are a generated ramp stand-in. Real art will move the numbers — the
*structural* claims (break-evens, crossover points, monotonicity) are the robust ones.
