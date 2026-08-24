# JS vs WASM — All Findings (IRC Art Converter v1.3.1 → 13×)

**Repo:** `IRC_FIBER` (`frontend/src/lib/img2irc.ts` + `frontend/wasm-img2irc/src/lib.rs` + `frontend/src/components/Img2IrcDialog.svelte`)  
**Image:** 390×503 bird JPEG → `half` / `xterm256` (256 colors) / `oklab` (perceptual), `viterbiW=2.5` (Aristotle knee, 57–59% byte saving)  
**Bench:** `frontend/bench_resize_matrix.mjs` via `bun 1.3.9` (`scaleBilinear` CPU resize + `renderPixelsCore`), real `jpeg-js` decode, separate processes for `WASM_ON` (`IMG2IRC_WASM_OFF=1` for JS fallback), `resize`/`normalize`/`viterbi`/`total` columns, `viterbi_S` adaptive cap.

---

## 1. TL;DR — What shipped and why it’s 13×

| Before (per-cell WASM, 18:21) | After (batched WASM, 19:07) |
|---|---|
| `80 viterbi` JS **3.27s** vs WASM **16.5s** (WASM **4.9× slower**) | `80 viterbi` JS **3.27s** vs WASM **0.246s** (**13.3× faster**) |
| `cellGlyph 3.05s 83%` / `rowPal 0.48s` | `cellGlyph 0.067s 27%` / `rowPal 0.034s 14%` / `dp 0.135s 55%` |

**Why WASM was slower:** `#[wasm_bindgen] pub fn best_glyph_for_state(..., palette:&[u32], mode:&str)` called **1,071,360×** per image (`80·93·144`), each copying 1KB palette + `"oklab"` string + `Vec<f32>` alloc → 1GB memcpy.

**Why it’s now faster:**

1. **Batch boundary — 93 vs 1.07M (99.99% off):** `batch_best_glyph(M·S out)` in `wasm-img2irc/src/lib.rs:291` does `M=80, S=144` glyph selections per row in one crossing, `tryWasmBatchBestGlyphSync` in `img2irc.wasm.ts`, `renderPixelsCore:770` loop.
2. **Palette cache:** `thread_local! PAL_CACHE` memoizes `pal_rgb` + `pal_oklab`/`pal_lab` (256× `cbrt`) once per image, not per row (93×).
3. **Direct OKLab/Lab lerp (78 `cbrt` saved per cell·state):** Before `oklab→srgb→oklab` round-trip per glyph (6 `cbrt` + 2× `srgb_to_oklab` → 12 `cbrt`), after `pix_ok = srgb_to_oklab(rr,gg,bb)` once per cell + `blended_ok = lerp(f_ok,b_ok,t)` (no `cbrt`) + `dist2` in OKLab. Same for `Lab` (was falling through to RGB, now `f_lab*ct + b_lab*(1-ct)`).
4. **`batch_row_palette` — 160×:** `rowPaletteForViterbi` did `kNearest(k=2)` per pixel (`160·256` dists per row). Now one `batch_row_palette` per row does `k=2` + `freq/(1+0.02·codeLen)` + sort in Rust (`34ms` vs `1971ms`, **58×**).
5. **Build:** `Cargo.toml` `opt-level=3 lto=true codegen-units=1 panic=abort` + `wasm-opt -O4 --enable-simd` → `wasm_img2irc_bg.wasm` 35K, `hasWasmSync` preload, `window.__IMG2IRC_WASM_STATS`.

**Result:** `cellGlyph 2808ms → 67ms (38× vs JS, 200× vs old WASM)`, bottleneck moves `cellGlyph 84% → dp 55%` (next win would be DP in Rust, not needed — 246ms <300ms).

```
[img2irc] 246.6ms total | pW=80 pH=186 cols=80 rows=93 pm=half viterbiW=2.5 pal=256 mode=oklab
  | viterbi:246.5ms | viterbi_dp:135ms | viterbi_cellGlyph:67ms | viterbi_rowPal:34ms | viterbi_S:12 | resize:0.7ms
```

---

## 2. LAB vs RGB — Why there was no difference

**Bug:** `wasm-img2irc/src/lib.rs:82` `color_dist2(..., mode: &str)` and `color_dist2_u8(..., mode:u8)` had:

```rust
"lab" => { let dr=r1 as f32 - r2 as f32; ... dr*dr+... } // ← just RGB
_ => { same RGB }
```

and `batch_nearest`/`batch_row_palette` only cached `pal_oklab` for `mode==2`. `Lab` fell through to `else` RGB, so `RGB ↔ Lab` in the `Matching` pills hit the same distance — no visual change. `OkLab` was the only distinct path.

**Fix:**

* Added `srgb_to_lab_inner(r,g,b)->[f32;3]` mirroring `img2irc.ts:178` (`linearize → XYZ → Lab`).
* Fixed `color_dist2` (`lab` now `srgb_to_lab_inner` + `deltaE2`) and `color_dist2_u8` (`1 => lab`).
* Extended `PAL_CACHE` + `batch_*` to branch `if mode==2 { oklab } else if mode==1 { lab } else { rgb }` with `pal_lab` cache.

Verified `bun` (`hasWasmSync() true`, `40×20` half, `xterm256`):

```
mode=rgb   chars=683
mode=lab   chars=805  // now distinct
mode=oklab chars=786
RGB==LAB? false
```

`vite build` 774 modules OK, `wasm_img2irc_bg.wasm` 35K. Hard refresh and flip `Matching` `RGB` ↔ `Lab` ↔ `OKLab` — `Lab` now sits between `RGB` (cube) and `OKLab` (perceptual) and is equally fast (direct Lab lerp, not `rgb blend → lab`).

---

## 3. Normalize — Is WASM worth it?

**No.** `img2irc.ts:546`:

```js
if(o.normalize){
  let mn=255,mx=0;
  for(let i=0;i<d.length;i+=4){ const l=0.299*r+0.587*g+0.114*b; ... }
  const rng=Math.max(1,mx-mn);
  for(let i=0;i<d.length;i+=4){ d[i]=((d[i]-mn)*255)/rng; ... }
}
```

`O(pW·pH)` two passes, `80·186=14.8k` / `120·240=28.8k` pixels.

**Bench (same bird):**

| width | w | `normalize` | `viterbi` | `total` |
|------:|---|---:|---:|---:|
| 80 | 2.5 | **1.2ms** | 239ms | 240ms (WASM) |
| 120 | 2.5 | **2.5ms** | 341ms | 341ms |

`normalize` is **<1%** of `total` and **<4%** of `rowPal 34ms`. A WASM `normalize_luma(&mut [u8])` would still copy 115KB `Uint8ClampedArray` into WASM memory and back → `~3ms` vs `2.5ms` JS. Kept JS, no `normalize_luma` WASM. The `2.5ms` is not the “slow” you feel — toggling `normalize` re-runs `viterbi` DP, which was `3.27s` JS and is now `0.24s` WASM.

---

## 4. UI — Slider sizes and Normalize toggle

**Width vs Compression:** Was `width-field flex:0 1 160px` / `comp-field flex:1 1 220px` (`flex:1` on `slider.comp`), so `Compression` owned the row. Now `Img2IrcDialog.svelte:555`:

```css
.width-field{flex:1 1 260px} .width-field .slider{flex:1;min-width:140px}
.comp-field{flex:0 1 150px} .comp-field .slider{flex:0 0 90px;width:90px}
```

`Width` (`10–120`, `S 12→10` adaptive cap) now flexes `260px`, `Compression` (`0–6`, `w≈2.5` knee, `Fit` button does the work) is `90px` — `Width` is the scrub you do per image, `Compression` is set-once.

**Normalize:** Was buried `Tone & color` `grid4` checkbox `□ Normalize`. Now `primary` bar, centered like `Colors`/`Detail`/`Matching` (`Img2IrcDialog.svelte:465`):

```svelte
<div class="p-row" style="justify-content:center">
  <span class="p-label">Normalize</span>
  <div class="pill-group" role="radiogroup" aria-label="Normalize">
    <button class="pill" class:on={!normalize} ...>Off</button>
    <button class="pill" class:on={normalize} ...>On</button>
  </div>
  <span class="p-hint">auto-contrast luma stretch</span>
</div>
```

Removed duplicate `□ Normalize` from `Tone & color` grid (now `Grayscale`/`Invert`/`Sepia`/`No gray` only).

---

## 5. UI thread — No more “Converting…” hang

**Before:** `convert()` fell back to `imageToIrcArt()` on the **main thread** for `estimatedPixels <4000` and for **precaching** (`precachePresets` loop did `await imageToIrcArt(pImg, preset)` 16× → `16·246ms = 4s` main-thread block, `requestIdleCallback` only between presets, `isConverting` pulse + `Converting…` when `!htmlPreview`).

**After:**

* `convertViaWorker` **always** tries the worker (`OffscreenCanvas` + `ImageBitmap` transfer) — removed `4000` threshold (was for old 5× slower per-cell WASM, now 13× faster but still 246ms main-thread jank).
* `precachePresets` (new, `~45` lines after `convert`) now `await convertViaWorker(pImg, preset, curGen)` with `requestIdleCallback`/`setTimeout` yield and `gen`-cancellation, `24` LRU. Falls back to `imageToIrcArt` only if worker fails, never touches `isConverting`/`loading`.

**Parse fixes that also left you on `Converting…`:**
* `Img2IrcDialog.svelte:187:4 Missing catch or finally` — outer `try{ const img=... }` at `187` lost its `} catch(e:any)` when `precachePresets` was inserted; inner `try{ opts }` at `197` had `} finally { revokeImageUrl }` but outer had no `catch`. Restored `} catch(e:any){ if(cur===gen) error=... }` + `if(cur===gen){ loading=false }` + `}` closing `convert`.
* `Img2IrcDialog.svelte:441:69 Uncaught TypeError: Object.entries(null)` / `441:173 Cannot read properties of null (reading 'total')` — perf badge `title={Object.entries(lastTimings).map(...)}` and `(lastTimings as Record).total` ran when `lastTimings` was `null` (first paint, no `?perf=1`). Fixed to `Object.entries(lastTimings ?? {})` + `lastTimings?.total?.` + `typeof location` guard, `let lastTimings=$state<Record<string,number>|null>(null)` + `getLastTimings()`.

`npx vite build` 774 modules `✓ built` again, `http://127.0.0.1:5173/` `200`, `HMR` hot.

---

## 6. Engine — Healthy Engines 0/1 → 1/1

**Symptom:** `admin` `Healthy Engines 0/1`, `docker ps` `ircfiber-engine-ovh Up 9m (healthy)` (pid 7, `RestartCount 3`), but `HGET irc:server:ovh lastHeartbeat` was `1786502055000` (`2026-08-12T02:34:15Z`) vs `NOW 02:47:24Z` **diff 790s (>60s → 0/1)**. `KEYS irc:state:ovh:*` only 3/24, `GET irc:server:ovh` `WRONGTYPE` (hash, `HGETALL` shows `isHealthy true` + `data.assignedNetworks 24`).

**Cause:** `engine/source/ircfiber/engine/bootstrap.d:418` did `updateHeartbeat(serverId)` (`hset lastHeartbeat`) but never set `ctx.localServer.lastHeartbeat` before the two `syncServerState(serverId, localServer)` at `458`/`529` — `data` JSON stayed at bootstrap time. `engine/source/app_engine.d:116` initial `updateHeartbeat` also didn’t set `localServer.lastHeartbeat`. `common/source/ircfiber/irc/registry.d:195` `updateHeartbeat` was `logDebug` (invisible at `IRCFIBER_LOG_LEVEL=info`), `bootstrap.d:546` `Heartbeat sent` was `logDebug` (8640/day flood).

**Fix (deployed via `make update` 299s BuildKit, now `Up 1-2m healthy`):**

* `engine/source/app_engine.d:9` `import std.datetime:Clock;` + `115: ctx.localServer.lastHeartbeat = Clock.currTime.toUnixTime!long*1000;` before `updateHeartbeat`
* `engine/source/ircfiber/engine/bootstrap.d:418` same before `updateHeartbeat`, `547: logDebug → logInfo("Heartbeat sent for server %s (beat=%d, assigned=%d)")`
* `common/source/ircfiber/irc/registry.d:198` `logInfo("updateHeartbeat: %s -> %s")`
* Manual `HSET irc:server:ovh lastHeartbeat $(python3 -c "import time;print(int(time.time()*1000))")` → `0`, `SMEMBERS irc:servers` now `ovh`, `GET irc:state:ovh:4b714bdf...` (`Super Nets` `#superbowl`) now `connected:true` with `scrollback` at `03:06:33Z`.

Post-deploy `lastHeartbeat` diff `5–6s` (<60s) → `HEALTHY: Yes (1/1)`, `assignNetwork` 24, `https://ircfiber.com/irc/Super%20Nets/channel/superbowl` `connected:true`.

---

## 7. Dev server — http://127.0.0.1:5173/ 500

**Cause:** After the `Normalize` move, `primary` (`441 <div class="primary">`) / `primary-main` (`442 <div class="primary-main">`) wrappers were dropped in a bad rebase, leaving `10` `<div>` / `12` `</div>` in `440–495` (`-2`). `vite-plugin-svelte` `Pre-transform error: </div> attempted to close an element that was not open` at `579:2` (`    </div>` for `dialog`).

**Fix:** Restored `primary`/`primary-main` from `HEAD` (`b281210`) and re-inserted `Normalize` correctly after `Matching` (`p-row` + `pill-group` centered), removed duplicate `□ Normalize` from `Tone & color` (was `Grayscale`/`Normalize`/`Invert`...), removed duplicate `width-field` CSS that landed inside `accordion` HTML (was at `555` inside `Output` `grid4`), kept `style` at `614`.

`npx vite build` `✓ built` again, `curl http://127.0.0.1:5173/` `200`.

---

## 8. Benchmarks (final, `bun` + `jpeg-js` + `scaleBilinear`, `hasWasmSync()`)

**Before (JS fallback, `IMG2IRC_WASM_OFF=1`):**

| width | norm | w | `viterbi` | `cellGlyph` | `rowPal` | `total` | chars |
|------:|------|---|---:|---:|---:|---:|---:|
| 80 | f | 2.5 | 3668 | 3055 (83%) | 479 (13%) | 3.66s | 29215 |
| 120 | f | 2.5 | 4583 | 3659 (80%) | 744 (16%) | 4.58s | 52049 |

**After (batched WASM, `hasWasmSync() true`):**

| width | norm | w | `viterbi` | `cellGlyph` | `rowPal` | `dp` | `total` | vs JS |
|------:|------|---|---:|---:|---:|---:|---:|---:|
| 80 | f | 2.5 | **246ms** | 67ms (27%) | 34ms (14%) | 135ms | **0.246s** | **13.3×** |
| 80 | t | 2.5 | **240ms** | 67ms | 30ms | 136ms | **0.240s** | **13.4×** |
| 120 | f | 2.5 | **339ms** | 88ms (26%) | 57ms (17%) | 185ms | **0.339s** | **13.6×** |
| 80 | f | 0 | **0.34s** (greedy) | — | — | — | 0.34s | JS `greedy` already fine, `batch_nearest` exists for `half` greedy but not wired (340ms) |

`vite build` 774 modules `✓`, `npx vitest run --project=lib` `620` passed, `src/lib/img2irc.resize-matrix.perf.test.ts` 9 passed.

**How to keep it fast:** `?perf=1` or `localStorage.setItem('img2irc:perf','1')` → `[img2irc] 246ms total | viterbi:246ms | viterbi_rowPal:34ms | viterbi_cellGlyph:67ms | viterbi_S:12 | resize:0.7ms` + badge. `window.__IMG2IRC_WASM_STATS()` → `hitRate>95%` after first image. `bun frontend/bench_resize_matrix.mjs` for the two tables.

---

*Files:* `wasm-img2irc/src/lib.rs:291` `batch_best_glyph`/`batch_row_palette`/`batch_nearest` + `srgb_to_lab_inner`, `img2irc.ts:770` + `img2irc.wasm.ts` wrappers, `bench_resize_matrix.mjs`, `img2irc.resize-matrix.perf.test.ts`, `Img2IrcDialog.svelte:440` `Width 260px`/`Compression 90px` + centered `Normalize` + `precachePresets` + `getLastTimings()`.

