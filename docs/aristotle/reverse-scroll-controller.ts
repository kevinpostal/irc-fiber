/**
 * Reference controller for IRC Fiber's flicker-free reverse infinite scroll.
 *
 * This is the executable counterpart of the Lean specification in
 * `ChatInfinite/`.  Every non-obvious step is annotated with the theorem that
 * justifies it:
 *
 *   ChatInfinite.scrollTopPreservedAfterPrepend   compensated prepend keeps the viewport
 *   ChatInfinite.noFlickerSameFrame               the prepend frame sequence has a constant anchor
 *   ChatInfinite.naivePrependFlickers             deferring compensation to rAF provably jumps
 *   ChatInfinite.sentinelPreloadFiresBeforeTop    200px rootMargin preload band
 *   ChatInfinite.noWedgeAtTop                     no wedge when stranded at scrollTop === 0
 *   ChatInfinite.atBottomStickiness               70px stick band: re-engage down, never yank up
 *   ChatInfinite.boundedWindow / applyTrim_idempotent   DOM stays O(BATCH_SIZE)
 *   ChatInfinite.stableKeyUnchangedByPrepend      keys survive prepends (ANSI art is not recreated)
 *   ChatInfinite.noDuplicatesAfterPrepend         dedup by eid/msgid
 *   ChatInfinite.prependDedup_idempotent          replaying a batch is a no-op
 *   ChatInfinite.noGaps / paginationMeasureDecreases / loadOlder_cursor_strict
 *                                                 cursor is a strict total order, no gaps, no stall
 *   ChatInfinite.progressiveLoadTerminates        silent fill loop is bounded by MAX_SILENT_FILLS
 *   ChatInfinite.eventuallyScrollableOrExhausted  it halts scrollable, exhausted, or fill-capped
 *   ChatInfinite.noDroppedRealtime / frozenRenderEndWhileScrolledUp / flushPendingDelivers
 *                                                 realtime is buffered while scrolled up, never lost
 *   ChatInfinite.realtimeCommutesWithHistoryLoad  backfill never blocks or reorders live messages
 *
 * The code is Svelte 5 runes style with no external dependency; it is meant to
 * be split across `LoadMore.svelte` (sentinel + probe), `MessageList.svelte`
 * (window + keys + anchored prepend) and `ChatArea.svelte` (wiring).
 *
 * ---------------------------------------------------------------------------
 * Why `jonasgeiler/svelte-infinite-loading` was evaluated and rejected
 * ---------------------------------------------------------------------------
 *  - Svelte 3/4 component: slot-based API, no runes, no `$props()`; it needs a
 *    compatibility wrapper to mount inside a Svelte 5 app at all.
 *  - No reverse-scroll primitive: it is written for "load more at the bottom".
 *    Reverse mode is emulated with `direction="top"` but it does not touch
 *    `scrollTop`, so every prepend jumps — exactly the state
 *    `ChatInfinite.naivePrependFlickers` proves to be observable.
 *  - No windowing/trimming: the DOM grows without bound, which is fatal with
 *    20-100 line ANSI-art rows.  Our `applyTrim` keeps the window ≤ 350 rows
 *    (`ChatInfinite.boundedWindow`).
 *  - No stick band, no frozen render end, no silent probe: none of
 *    requirements 2, 3 and 5 are addressed.
 *  - Unmaintained (last release ~2 years ago), while the native
 *    `IntersectionObserver` sentinel it would replace is ~8 lines we fully
 *    control.
 *  If a virtualizer ever becomes necessary, `@tanstack/svelte-virtual` with a
 *  variable-height estimator is the next step — but variable-height ANSI art
 *  makes measurement caching costly, so bounded windowing stays preferred.
 */

// ---------------------------------------------------------------------------
// Tunables — must match ChatInfinite/Scroll.lean
// ---------------------------------------------------------------------------

export const BATCH_SIZE = 200;
export const TRIM_DETECT_THRESHOLD = 350;
export const STICK_BAND_PX = 70;
export const SENTINEL_MARGIN_PX = 200;
export const MAX_SILENT_FILLS = 3;
export const PAGE_COUNT = 150;
export const DIVIDER_DELAY_MS = 200;
export const FILL_DEBOUNCE_MS = 150;

export interface ChatMessage {
  eid: string; // total-order event id (primary dedup + cursor key)
  msgid?: string; // fallback identity for optimistic → echo swaps
  ts: number; // fallback cursor component
}

export interface HistoryPage {
  messages: ChatMessage[]; // ascending by eid, all strictly older than the cursor
  earliest_eid: string | null;
  earliest_ts: number | null;
  hasMore: boolean;
}

export type LoadHistory = (cursor: {
  beforeid: string | null;
  before: number | null;
  count: number;
}) => Promise<HistoryPage>;

// ---------------------------------------------------------------------------
// Pure helpers (the ones the Lean model formalises)
// ---------------------------------------------------------------------------

/** Total order on the cursor: eid primary, ts fallback. Mirrors `Msg.eid`. */
export function cursorLt(a: ChatMessage, b: ChatMessage): boolean {
  return a.eid === b.eid ? a.ts < b.ts : a.eid < b.eid;
}

/**
 * `prependDedup`: merge an older page in front of the buffer, dropping any
 * message whose eid (or msgid) is already present.
 *
 * Lean: `ChatInfinite.prependDedup`, proved duplicate-free
 * (`noDuplicatesAfterPrepend`), order-preserving (`Ordered.prependDedup`),
 * lossless (`old_subset_prependDedup`) and idempotent
 * (`prependDedup_idempotent`) — replaying the same batch changes nothing, so a
 * double-fired sentinel cannot double-render.
 */
export function prependDedup(old: ChatMessage[], page: ChatMessage[]): ChatMessage[] {
  const seen = new Set<string>();
  for (const m of old) {
    seen.add(m.eid);
    if (m.msgid) seen.add(m.msgid);
  }
  const fresh = page.filter((m) => !seen.has(m.eid) && !(m.msgid && seen.has(m.msgid)));
  return fresh.length === 0 ? old : fresh.concat(old);
}

/**
 * Stable render key.  Counting from the *bottom* is what makes the key
 * invariant under prepends: Lean `ChatInfinite.stableKeyUnchangedByPrepend`.
 * `base` is the buffer identity (network#channel plus `clearedAt`).
 */
export function stableKey(base: string, total: number, indexFromTop: number): string {
  return `${base}#${total - 1 - indexFromTop}`;
}

/** `ChatInfinite.applyTrim`: trim to BATCH_SIZE once the window exceeds TRIM_DETECT_THRESHOLD. */
export function trimStart(renderStart: number, total: number): number {
  return total - renderStart > TRIM_DETECT_THRESHOLD
    ? Math.max(renderStart, total - BATCH_SIZE)
    : renderStart;
}

// ---------------------------------------------------------------------------
// The controller
// ---------------------------------------------------------------------------

export interface ControllerOpts {
  /** the scroll container */
  getEl: () => HTMLElement | null;
  /** synchronous DOM flush (Svelte 5 `flushSync`) */
  flushSync: (fn: () => void) => void;
  /** the store: returns the number of rows and the pixel delta it inserted */
  applyPage: (page: ChatMessage[]) => void;
  /** rows already in memory above the render window, revealed without a fetch */
  revealFromMemory: () => number;
  loadHistory: LoadHistory;
}

export class ReverseScrollController {
  // ---- reactive state (Svelte 5 runes) ------------------------------------
  // In a .svelte.ts module these are `$state(...)`:
  //   let loading = $state(false); … etc.
  loading = false;
  noMoreHistory = false;
  cleared = false;
  atBottom = true;
  /** frozen while the user is scrolled up (requirement 2) */
  renderEndKey = 0;
  renderStart = 0;
  pending: ChatMessage[] = [];
  buf: ChatMessage[] = [];
  cursorEid: string | null = null;
  cursorTs: number | null = null;

  private fills = 0;
  private probed = false;
  private lastTop = 0;
  private rafId = 0;
  private io: IntersectionObserver | null = null;
  private armed = false;

  constructor(private readonly o: ControllerOpts) {}

  // -------------------------------------------------------------------------
  // 1. Sentinel: preload 200px before the top
  //    Lean: sentinelPreloadFiresBeforeTop, noWedgeAtTop, shouldLoad_false_of_guard
  // -------------------------------------------------------------------------

  mountSentinel(sentinel: HTMLElement) {
    const root = this.o.getEl();
    if (!root) return;
    this.io = new IntersectionObserver(
      (entries) => {
        if (!this.armed) return; // armed on first scroll, not on mount:
        if (!entries.some((e) => e.isIntersecting)) return; // avoids the transient
        void this.tryAutoLoad(); // scrollTop===0 before snap-to-bottom
      },
      { root, rootMargin: `${SENTINEL_MARGIN_PX}px 0px 0px 0px`, threshold: 0 },
    );
    this.io.observe(sentinel);
  }

  /** The guard of `onSentinelVisible`; Lean `ChatInfinite.shouldLoad`. */
  private shouldLoad(el: HTMLElement): boolean {
    if (this.loading || this.noMoreHistory || this.cleared) return false;
    return el.scrollHeight > el.clientHeight;
  }

  // -------------------------------------------------------------------------
  // 2. Scroll handler: rAF-coalesced, 70px stick band
  //    Lean: atBottomStickiness, notSticky_outside_band
  // -------------------------------------------------------------------------

  onScroll() {
    if (this.rafId) return; // coalesce all layout reads into one frame
    this.rafId = requestAnimationFrame(() => {
      this.rafId = 0;
      const el = this.o.getEl();
      if (!el) return;
      this.armed = true;
      const top = el.scrollTop;
      const scrolledUp = top < this.lastTop;
      const dist = el.scrollHeight - (top + el.clientHeight);
      // Upward movement always disengages stickiness — even inside the band —
      // so reading 50px up is never yanked back (Lean: atBottomStickiness.2).
      this.atBottom = scrolledUp ? false : dist <= STICK_BAND_PX;
      this.lastTop = top;
      if (this.atBottom) this.flushPending();
      // Sentinel semantics without waiting for the IO callback: no dead zone.
      if (top <= SENTINEL_MARGIN_PX && this.shouldLoad(el)) void this.tryAutoLoad();
    });
  }

  // -------------------------------------------------------------------------
  // 3. Realtime appends: frozen render end while scrolled up
  //    Lean: noDroppedRealtime, frozenRenderEndWhileScrolledUp, flushPendingDelivers
  // -------------------------------------------------------------------------

  receiveRealtime(msg: ChatMessage) {
    if (this.atBottom) {
      this.buf = this.buf.concat(msg); // rendered now
      this.renderEndKey = this.buf.length; // render end advances by exactly 1
      this.snapToBottom();
    } else {
      this.pending = this.pending.concat(msg); // queued: zero layout work
    }
    this.maybeTrim();
  }

  /** Called when stickiness re-engages; delivers the queue exactly once, in order. */
  flushPending() {
    if (this.pending.length === 0) return;
    this.buf = this.buf.concat(this.pending);
    this.pending = [];
    this.renderEndKey = this.buf.length;
    this.maybeTrim();
    this.snapToBottom();
  }

  // -------------------------------------------------------------------------
  // 4. Scroll-anchored prepend — atomic within one frame
  //    Lean: scrollTopPreservedAfterPrepend, noFlickerSameFrame, naivePrependFlickers
  // -------------------------------------------------------------------------

  /**
   * Mutate the DOM and fix `scrollTop` inside the *same* synchronous flush.
   * Reading `scrollHeight` after `flushSync` forces layout exactly once; the
   * compensation is applied before the frame is presented, so no intermediate
   * state with the old `scrollTop` and the new `scrollHeight` is ever painted.
   */
  private anchoredMutate(mutate: () => void): number {
    const el = this.o.getEl();
    if (!el) {
      mutate();
      return 0;
    }
    const oldHeight = el.scrollHeight;
    const oldTop = el.scrollTop;
    this.o.flushSync(mutate);
    const delta = el.scrollHeight - oldHeight; // single layout read
    if (delta !== 0) el.scrollTop = oldTop + delta; // scrollTop' = scrollTop + d
    return delta;
  }

  // -------------------------------------------------------------------------
  // 5. Load path: reveal-from-memory, else network page
  //    Lean: loadOlder_invariant, loadOlder_cursor_strict, noGaps
  // -------------------------------------------------------------------------

  async tryAutoLoad(silent = false): Promise<boolean> {
    const el = this.o.getEl();
    if (!el || !this.shouldLoad(el)) return false;
    this.loading = true;
    let dividerTimer = 0;
    try {
      // (a) instant path: rows already in the store above the window
      const revealed = this.o.revealFromMemory();
      if (revealed > 0) {
        this.anchoredMutate(() => {
          this.renderStart = Math.max(0, this.renderStart - revealed);
        });
        return true;
      }
      // (b) network path; the "Fetching…" divider is delayed, and suppressed
      //     entirely for silent viewport fills (requirement 3)
      if (!silent) dividerTimer = window.setTimeout(() => this.showDivider(true), DIVIDER_DELAY_MS);
      const page = await this.o.loadHistory({
        beforeid: this.cursorEid,
        before: this.cursorTs,
        count: PAGE_COUNT,
      });
      if (page.messages.length === 0) {
        this.noMoreHistory = true; // hides LoadMore for good
        return false;
      }
      // The cursor moves to the *earliest* returned message and therefore
      // decreases strictly: no phantom UUID can stall the pagination
      // (Lean: loadOlder_cursor_strict, paginationMeasureDecreases).
      const earliest = page.messages[0];
      if (this.cursorEid !== null && !(earliest.eid < this.cursorEid)) {
        this.noMoreHistory = true; // defensive: backend violated the order
        return false;
      }
      this.cursorEid = page.earliest_eid ?? earliest.eid;
      this.cursorTs = page.earliest_ts ?? earliest.ts;
      this.noMoreHistory = !page.hasMore;
      this.anchoredMutate(() => {
        // The store shift and the reveal cancel on `renderStart`
        // (Lean: prependCompensate_eq), so only the buffer grows.
        this.buf = prependDedup(this.buf, page.messages);
        this.o.applyPage(page.messages);
      });
      return page.hasMore;
    } finally {
      if (dividerTimer) clearTimeout(dividerTimer);
      this.showDivider(false);
      this.loading = false;
    }
  }

  // -------------------------------------------------------------------------
  // 6. Silent probe + bounded viewport-fill loop
  //    Lean: progressiveLoadTerminates, eventuallyScrollableOrExhausted,
  //          autoFill_preserves_anchor, autoFill_pages_suffix
  // -------------------------------------------------------------------------

  /** Once per buffer: learn `hasMore` without ever flashing the divider. */
  async silentProbe() {
    if (this.probed || this.noMoreHistory) return;
    this.probed = true;
    const hasMore = await this.tryAutoLoad(true);
    if (!hasMore) this.noMoreHistory = true;
  }

  /**
   * Fill the viewport so the sentinel can be reached at all.  Bounded by
   * MAX_SILENT_FILLS and by "no progress" (the scrollHeight delta), hence it
   * always terminates in a state that is scrollable, exhausted, or capped.
   */
  async tryAutoFillSilent() {
    const el = this.o.getEl();
    if (!el) return;
    this.fills = 0;
    while (this.fills < MAX_SILENT_FILLS) {
      if (el.scrollHeight > el.clientHeight) return; // scrollable
      if (this.noMoreHistory) return; // exhausted
      const before = el.scrollHeight;
      const more = await this.tryAutoLoad(true);
      this.fills += 1;
      if (!more || el.scrollHeight === before) return; // no progress ⇒ stop
      await new Promise((r) => setTimeout(r, FILL_DEBOUNCE_MS));
    }
  }

  // -------------------------------------------------------------------------
  // 7. Bounded window
  //    Lean: boundedWindow, applyTrim_idempotent, windowBoundInvariant
  // -------------------------------------------------------------------------

  private maybeTrim() {
    const next = trimStart(this.renderStart, this.buf.length);
    if (next === this.renderStart) return; // O(1) amortised, idempotent
    // Rows leaving the top are above the viewport, so compensate downwards
    // with the same anchoring rule used by the prepend.
    this.anchoredMutate(() => {
      this.renderStart = next;
    });
  }

  private snapToBottom() {
    const el = this.o.getEl();
    if (!el || !this.atBottom) return; // only a sticky view is snapped
    el.scrollTop = el.scrollHeight; // double set + reflow read defeats
    void el.scrollHeight; // late image/font layout
    el.scrollTop = el.scrollHeight;
  }

  private showDivider(_visible: boolean) {
    /* bind to the `Fetching…` divider in LoadMore.svelte */
  }

  destroy() {
    this.io?.disconnect();
    if (this.rafId) cancelAnimationFrame(this.rafId);
  }
}

/*
 * Svelte 5 wiring sketch
 * ----------------------
 * // MessageList.svelte
 * let { base, messages, renderStart, renderEndKey } = $props();
 * const rows = $derived(messages.slice(renderStart, renderEndKey));
 * {#each rows as m, i (stableKey(base, messages.length, renderStart + i))}
 *   <Row {m} />
 * {/each}
 *
 * // LoadMore.svelte
 * let { controller } = $props();
 * let sentinel: HTMLElement;
 * $effect(() => { controller.mountSentinel(sentinel); return () => controller.destroy(); });
 * <div bind:this={sentinel} style="height:1px"></div>
 *
 * // ChatArea.svelte
 * const ctrl = new ReverseScrollController({ getEl: () => scrollEl, flushSync, … });
 * $effect(() => { void ctrl.silentProbe(); });
 * $effect(() => { void ctrl.tryAutoFillSilent(); });
 * <div class="scroll" bind:this={scrollEl} onscroll={() => ctrl.onScroll()}
 *      style="overflow-anchor:auto"> … </div>
 */
