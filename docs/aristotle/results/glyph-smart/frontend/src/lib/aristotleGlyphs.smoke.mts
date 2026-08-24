/**
 * Smoke test for aristotleGlyphs.ts — run with:
 *   node --experimental-strip-types frontend/src/lib/aristotleGlyphs.smoke.mts
 *
 * Each expected value is a theorem of frontend/wasm-img2irc/lean/GlyphSmart.lean.
 */
import * as G from './aristotleGlyphs.ts';

let failures = 0;
function check(name: string, actual: unknown, expected: unknown): void {
  const ok = String(actual) === String(expected);
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${actual}${ok ? '' : ` (expected ${expected})`}`);
}

// optimal_block_coverage / bandError_optimal_beats_measured
check('optimalBlockCoverage(0.273)', G.OPTIMAL_BLOCK_COVERAGE.toFixed(4), '0.4243');
check('bandError at r*', G.bandError(0.273, G.OPTIMAL_BLOCK_COVERAGE).toFixed(6), '0.075667');
check('bandError at 0.494', G.bandError(0.273, 0.494).toFixed(6), '0.110500');
check(
  'improvement (%)',
  (100 * (1 - G.bandError(0.273, G.OPTIMAL_BLOCK_COVERAGE) / G.bandError(0.273, 0.494))).toFixed(2),
  '31.52',
);

// standardAlphabet / pareto frontier sizes
check('standardAlphabet size', G.standardAlphabet().length, G.MAX_ALPHABET);
check('frontier, w=2, contrast=12', G.paretoPrune(2, 12, 0, G.standardAlphabet()).length, 15);
check('frontier, w=4, contrast=12', G.paretoPrune(4, 12, 0, G.standardAlphabet()).length, 13);
check('flat cell collapses to space', G.paretoPrune(2, 2, 0, G.standardAlphabet()).length, 1);

// fits_512
const payload = (cfg: G.GlyphConfig): number =>
  cfg.width * (G.paletteBytes(cfg.palette) + Math.max(...cfg.alphabet.map((g) => g.bytes)));

const wide = G.compressToFit(
  { width: 80, viterbiW: 2, palette: 'smart', alphabet: G.standardAlphabet() },
  200,
  20,
  payload,
);
check('wide image fits 512', G.IRC_PREFIX_RESERVE + payload(wide.config) <= G.IRC_HARD_LIMIT, true);
check('wide image width >= 10', wide.config.width >= G.MIN_IRC_WIDTH, true);

const hopeless = G.compressToFit(
  { width: 400, viterbiW: 2, palette: 'smart', alphabet: G.standardAlphabet() },
  200,
  20,
  (cfg) => cfg.width * 50,
);
check('final guard fires', hopeless.message, G.TOO_DETAILED_MESSAGE);
check('final guard width', hopeless.config.width, G.MIN_IRC_WIDTH);
check('final guard palette', hopeless.config.palette, '16');
check('final guard alphabet', hopeless.config.alphabet.length, 2);

console.log(failures === 0 ? 'all checks passed' : `${failures} check(s) failed`);
if (failures > 0) process.exitCode = 1;
