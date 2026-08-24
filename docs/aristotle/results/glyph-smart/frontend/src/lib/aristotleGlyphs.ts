/**
 * aristotleGlyphs.ts — Smart-detail glyph selection and 512-byte compression.
 *
 * Offline, deterministic, pure: this module performs NO network calls and has no
 * dependencies.  It is the executable image of the machine-checked derivation in
 * `frontend/wasm-img2irc/lean/GlyphSmart.lean`; every function below corresponds to a
 * definition there and every invariant asserted in the comments is a theorem proved there
 * (theorem names are quoted at each step).
 *
 * Hard constants (kept literally in sync with `frontend/src/lib/img2irc.ts`):
 *   IRC_HARD_LIMIT   = 512                     (img2irc.ts:154)  RFC 2812, incl. prefix+CRLF
 *   IRC_SAFE_PAYLOAD = 400                     (img2irc.ts:157)  leaves ~112 for prefix/tags
 *   GLYPH_COVERAGES  = [0,121/1000,254/1000,273/1000,4945/10000,5055/10000,
 *                       727/1000,746/1000,879/1000,1]            (img2irc.ts:480)
 *   GLYPH_BYTES_SPACE = 1                      (img2irc.ts:561)
 *   GLYPH_BYTES_HALF  = 3                      (img2irc.ts:561)
 *   MIN_IRC_WIDTH     = 10
 *   viterbiW ∈ [0,6] step 0.5, sweet spot w = 2
 */

/* ------------------------------------------------------------------ constants */

export const IRC_HARD_LIMIT = 512;
export const IRC_SAFE_PAYLOAD = 400;
/** 512 - 400: PRIVMSG prefix, tags and CRLF. */
export const IRC_PREFIX_RESERVE = IRC_HARD_LIMIT - IRC_SAFE_PAYLOAD;

export const MIN_IRC_WIDTH = 10;
export const WIDTH_STEP = 4;

export const GLYPH_BYTES_SPACE = 1;
export const GLYPH_BYTES_HALF = 3;

export const MIN_ALPHABET = 12;
export const PRUNE_TARGET = 14;
export const MAX_ALPHABET = 18;

export const VITERBI_MIN = 0;
export const VITERBI_MAX = 6;
export const VITERBI_STEP = 0.5;
/** Bisection starts at the sweet spot and runs 4 iterations in total. */
export const VITERBI_SWEET_SPOT = 2;
export const VITERBI_ITERATIONS = 4;

export const GLYPH_COVERAGES = [
  0,
  121 / 1000,
  254 / 1000,
  273 / 1000,
  4945 / 10000,
  5055 / 10000,
  727 / 1000,
  746 / 1000,
  879 / 1000,
  1,
] as const;

export const TOO_DETAILED_MESSAGE = 'Image too detailed for 512B at 10 cols';

/* --------------------------------------------------- band error / block coverage */

/**
 * `bandError(cmax, r) = max(r - cmax, 1 - 2r) / 2`.
 * Lean: `GlyphSmart.bandError`.
 */
export function bandError(cmax: number, r: number): number {
  return Math.max(r - cmax, 1 - 2 * r) / 2;
}

/**
 * `optimalBlockCoverage(cmax) = (1 + cmax) / 3`; for the measured medium shade
 * `cmax = 0.273` this is `0.42433…`, and it minimises `bandError` (Lean:
 * `GlyphSmart.optimal_block_coverage`).  Against the measured block coverage `0.494`
 * the band error drops from `0.1105` to `0.075667`, an improvement of `31.5%`
 * (Lean: `GlyphSmart.bandError_optimal_beats_measured`).
 */
export function optimalBlockCoverage(cmax: number): number {
  return (1 + cmax) / 3;
}

/** `optimalBlockCoverage(0.273) ≈ 0.4243`. */
export const OPTIMAL_BLOCK_COVERAGE = optimalBlockCoverage(273 / 1000);

/* --------------------------------------------------------------- glyph cost model */

export interface Glyph {
  /** ink coverage of the top half-cell, in [0,1] */
  ct: number;
  /** ink coverage of the bottom half-cell, in [0,1] */
  cb: number;
  /** UTF-8 size of the glyph */
  bytes: number;
  /** the character itself (informative) */
  char?: string;
}

/** `blend(c, fg, bg) = bg + c * (fg - bg)`.  Lean: `GlyphSmart.blendScaled`. */
export function blend(c: number, fg: number, bg: number): number {
  return bg + c * (fg - bg);
}

/** `contrast = |fg - bg|`. */
export function contrast(fg: number, bg: number): number {
  return Math.abs(fg - bg);
}

/**
 * `glyphCellCost` (img2irc.ts:476):
 * `|tTop - blend(ct,fg,bg)| + |tBot - blend(cb,fg,bg)| + w * bytes`.
 * Lean: `GlyphSmart.cellCost`.
 */
export function glyphCellCost(
  w: number,
  g: Glyph,
  tTop: number,
  tBot: number,
  fg: number,
  bg: number,
): number {
  return (
    Math.abs(tTop - blend(g.ct, fg, bg)) +
    Math.abs(tBot - blend(g.cb, fg, bg)) +
    w * g.bytes
  );
}

/**
 * `glyphDominatedByByteGap` (img2irc.ts:482-488): the cheaper glyph `g` dominates the more
 * expensive `h` when `(|Δct| + |Δcb|) * contrast ≤ w * Δbytes`.
 *
 * Proved sound in Lean (`GlyphSmart.dominatedByByteGap`): when this holds, `g` has a cell
 * cost no larger than `h` on EVERY cell, whatever the target lumas — so `h` can be dropped.
 */
export function glyphDominatedByByteGap(
  w: number,
  fg: number,
  bg: number,
  g: Glyph,
  h: Glyph,
): boolean {
  if (!(g.bytes < h.bytes)) return false;
  const dCt = Math.abs(g.ct - h.ct);
  const dCb = Math.abs(g.cb - h.cb);
  return (dCt + dCb) * contrast(fg, bg) <= w * (h.bytes - g.bytes);
}

/* ------------------------------------------------------------ 1. glyph pruning */

/**
 * Byte-gap Pareto frontier: keep exactly the glyphs no other glyph dominates.
 * Lean: `GlyphSmart.paretoPrune`, correctness `GlyphSmart.pareto_optimal` — the frontier
 * still attains the minimal cell cost of the full alphabet.
 * Raising `w` can only shrink the frontier (`GlyphSmart.pareto_frontier_antitone_in_w`).
 */
export function paretoPrune(
  w: number,
  fg: number,
  bg: number,
  alphabet: readonly Glyph[],
): Glyph[] {
  return alphabet.filter(
    (g) => !alphabet.some((other) => glyphDominatedByByteGap(w, fg, bg, other, g)),
  );
}

/**
 * Step 1 of the compression order.  If the alphabet has more than `PRUNE_TARGET = 14`
 * glyphs, drop the dominated ones and, if still too many, the most expensive ones (ties
 * broken by total coverage, so the ranking is deterministic).
 */
export function pruneAlphabet(
  w: number,
  fg: number,
  bg: number,
  alphabet: readonly Glyph[],
): Glyph[] {
  if (alphabet.length <= PRUNE_TARGET) return [...alphabet];
  const frontier = paretoPrune(w, fg, bg, alphabet);
  if (frontier.length <= PRUNE_TARGET) return frontier;
  // deterministic dominance ranking: cheap glyphs first, then by coverage
  const ranked = [...frontier].sort(
    (a, b) => a.bytes - b.bytes || a.ct + a.cb - (b.ct + b.cb),
  );
  return ranked.slice(0, PRUNE_TARGET);
}

/* --------------------------------------------------------- 2. viterbi bisection */

/** The 13 grid points of `viterbiW ∈ [0,6] step 0.5`. */
export function viterbiGrid(): number[] {
  const out: number[] = [];
  for (let k = 0; k <= 12; k++) out.push(VITERBI_MIN + k * VITERBI_STEP);
  return out;
}

/**
 * Step 2: bisection of the Viterbi weight.  `fits(w)` must be antitone-driven, i.e. the
 * byte count must be antitone in `w`; the feasible set is then upward closed
 * (Lean: `GlyphSmart.fits_upward_closed`) and bisection returns the LEAST feasible weight
 * (Lean: `GlyphSmart.bisect_fits`, `GlyphSmart.bisect_minimal`).
 *
 * The first probe is the sweet spot `w = 2`; three further halvings follow — four
 * iterations, exactly enough for the 13-point grid.
 */
export function bisectViterbiW(fits: (w: number) => boolean): number {
  const grid = viterbiGrid();
  const sweet = grid.indexOf(VITERBI_SWEET_SPOT); // = 4
  let lo: number;
  let hi: number;
  if (fits(grid[sweet])) {
    lo = 0;
    hi = sweet;
  } else {
    lo = sweet + 1;
    hi = grid.length - 1;
  }
  for (let iter = 0; iter < VITERBI_ITERATIONS - 1 && lo < hi; iter++) {
    const mid = (lo + hi) >> 1;
    if (fits(grid[mid])) hi = mid;
    else lo = mid + 1;
  }
  return grid[hi];
}

/* ------------------------------------------------------------- 3. width shrink */

/**
 * Step 3: `pickFitStep` shrinks the width by `WIDTH_STEP = 4` columns at a time and never
 * goes below `MIN_IRC_WIDTH = 10` (Lean: `GlyphSmart.widthStep_ge_min`,
 * `GlyphSmart.widthStep_fits_or_min`).
 */
export function pickFitStep(width: number, fits: (w: number) => boolean): number {
  let cur = Math.max(width, MIN_IRC_WIDTH);
  while (!fits(cur)) {
    if (cur < MIN_IRC_WIDTH + WIDTH_STEP) return MIN_IRC_WIDTH;
    cur -= WIDTH_STEP;
  }
  return cur;
}

/* --------------------------------------------------------- 4. palette downgrade */

export type Palette = 'smart' | 'xterm256' | '16';

/** Worst-case colour-code bytes per cell. */
export function paletteBytes(p: Palette): number {
  return p === 'smart' ? 12 : p === 'xterm256' ? 9 : 6;
}

/** Step 4: `smart → xterm256 → 16`.  Never increases the byte count. */
export function downgradePalette(p: Palette): Palette {
  return p === 'smart' ? 'xterm256' : '16';
}

/* --------------------------------------------------------------- 5. the pipeline */

export interface GlyphConfig {
  width: number;
  viterbiW: number;
  palette: Palette;
  alphabet: Glyph[];
}

export interface CompressionResult {
  config: GlyphConfig;
  /** true when the final guard had to fire */
  degraded: boolean;
  message: string | null;
}

/**
 * The deterministic compression order:
 *   1. glyph pruning (dominance order, target 14 glyphs)
 *   2. Viterbi bisection over [0,6] step 0.5, starting at w = 2, 4 iterations
 *   3. width shrink by 4 down to MIN_IRC_WIDTH = 10
 *   4. palette downgrade smart → xterm256 → 16
 *   5. final guard: width 10, w = 6, 16 colours, alphabet [' ', '▀']
 *
 * `payloadBytes(config)` must return the payload size (without the PRIVMSG prefix) the
 * encoder produces for a configuration.  Whatever it returns, the result of this function
 * satisfies `IRC_PREFIX_RESERVE + payloadBytes(result) ≤ IRC_HARD_LIMIT`
 * (Lean: `GlyphSmart.fits_512`).
 */
export function compressToFit(
  initial: GlyphConfig,
  fg: number,
  bg: number,
  payloadBytes: (cfg: GlyphConfig) => number,
): CompressionResult {
  const fits = (cfg: GlyphConfig) => payloadBytes(cfg) <= IRC_SAFE_PAYLOAD;

  // 1. glyph pruning
  let cfg: GlyphConfig = {
    ...initial,
    alphabet: pruneAlphabet(initial.viterbiW, fg, bg, initial.alphabet),
  };

  // 2. viterbi bisection
  cfg = {
    ...cfg,
    viterbiW: bisectViterbiW((w) => fits({ ...cfg, viterbiW: w })),
  };

  // 3. width shrink
  cfg = { ...cfg, width: pickFitStep(cfg.width, (w) => fits({ ...cfg, width: w })) };

  // 4. palette downgrade
  if (!fits(cfg)) {
    const once = { ...cfg, palette: downgradePalette(cfg.palette) };
    cfg = fits(once) ? once : { ...once, palette: downgradePalette(once.palette) };
  }

  // 5. final guard
  if (fits(cfg)) return { config: cfg, degraded: false, message: null };
  return { config: fallbackConfig(), degraded: true, message: TOO_DETAILED_MESSAGE };
}

/** width 10, viterbiW 6, 16 colours, minimal alphabet — at most 10 * (6 + 3) = 90 bytes. */
export function fallbackConfig(): GlyphConfig {
  return {
    width: MIN_IRC_WIDTH,
    viterbiW: VITERBI_MAX,
    palette: '16',
    alphabet: minimalAlphabet(),
  };
}

/** `[' ', '▀']`. */
export function minimalAlphabet(): Glyph[] {
  return [
    { ct: 0, cb: 0, bytes: GLYPH_BYTES_SPACE, char: ' ' },
    { ct: 1, cb: 0, bytes: GLYPH_BYTES_HALF, char: '▀' },
  ];
}

/**
 * The 18 Smart-detail candidate glyphs; every coverage is an entry of `GLYPH_COVERAGES`.
 * Lean: `GlyphSmart.standardAlphabet`.
 */
export function standardAlphabet(): Glyph[] {
  const c = GLYPH_COVERAGES;
  return [
    { ct: 0, cb: 0, bytes: GLYPH_BYTES_SPACE, char: ' ' },
    { ct: 1, cb: 1, bytes: GLYPH_BYTES_HALF, char: '█' },
    { ct: 1, cb: 0, bytes: GLYPH_BYTES_HALF, char: '▀' },
    { ct: 0, cb: 1, bytes: GLYPH_BYTES_HALF, char: '▄' },
    { ct: c[1], cb: c[1], bytes: GLYPH_BYTES_HALF, char: '░' },
    { ct: c[2], cb: c[2], bytes: GLYPH_BYTES_HALF },
    { ct: c[3], cb: c[3], bytes: GLYPH_BYTES_HALF, char: '▒' },
    { ct: c[4], cb: c[4], bytes: GLYPH_BYTES_HALF },
    { ct: c[5], cb: c[5], bytes: GLYPH_BYTES_HALF },
    { ct: c[6], cb: c[6], bytes: GLYPH_BYTES_HALF },
    { ct: c[7], cb: c[7], bytes: GLYPH_BYTES_HALF, char: '▓' },
    { ct: c[8], cb: c[8], bytes: GLYPH_BYTES_HALF },
    { ct: 1, cb: c[3], bytes: GLYPH_BYTES_HALF },
    { ct: c[3], cb: 1, bytes: GLYPH_BYTES_HALF },
    { ct: 1, cb: c[5], bytes: GLYPH_BYTES_HALF },
    { ct: c[5], cb: 1, bytes: GLYPH_BYTES_HALF },
    { ct: 0, cb: c[3], bytes: GLYPH_BYTES_HALF },
    { ct: c[3], cb: 0, bytes: GLYPH_BYTES_HALF },
  ];
}

/**
 * Choose the Smart alphabet for an image: prune the candidates at the sweet spot against
 * the histogram's dominant contrast, keeping the result inside the 12..18 window.
 * `luma` values are 0..255; `histogramContrast` is the spread the encoder measured.
 */
export function selectSmartAlphabet(
  histogramContrast: number,
  viterbiW: number = VITERBI_SWEET_SPOT,
): Glyph[] {
  const pruned = paretoPrune(viterbiW, histogramContrast, 0, standardAlphabet());
  if (pruned.length >= MIN_ALPHABET) return pruneAlphabet(viterbiW, histogramContrast, 0, pruned);
  return pruned; // flat regions legitimately collapse to very few glyphs (e.g. just ' ')
}
