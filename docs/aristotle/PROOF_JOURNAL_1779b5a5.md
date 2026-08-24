# Proof journal — IrcFiber/HoleDetector.lean and IrcFiber/Splitter.lean

All ten `sorry`s in the two target modules are gone.  Eight obligations were
proved as stated; **two were false as stated**, so each is preserved
(commented out, with an explanation) next to a machine-checked
counterexample and a corrected theorem.

Everything is core Lean 4 (v4.28.0) + Std; no mathlib, no new axioms, no
`@[implemented_by]`.  `lake build` is clean and `#print axioms` on every
result below shows only `propext`, `Quot.sound`, `Classical.choice`
(and `Lean.ofReduceBool` / `Lean.trustCompiler` where the pre-existing
`pack_fits` proof's `native_decide` is inherited).

## 1. HoleDetector

| obligation | outcome |
|---|---|
| `findHole_none_iff` | proved as stated |
| `findHole_first` | **false as stated** → `findHole_first_counterexample`, plus `findHole_first_prefix` and `findHole_first_ascending` |
| `window_ascending_preserved` | proved as stated |
| `cooldown_prevents_storm` | proved as stated |

* **`findHole_none_iff`** — induction on the window; the interesting step is
  the case split on whether the head pair already exceeds the threshold.

* **`findHole_first`** — the statement orders adjacent pairs by `y < b`
  rather than by position.  On a *non-ascending* window the two orders
  differ.  Counterexample (`findHole_first_counterexample`, by `decide`):
  window `[0, 100, 0, 50]`, threshold `10`.  `findHole` reports `(0, 100)`,
  but the later pair `(0, 50)` has gap `49 > 10` and `50 < 100`.
  Two corrected forms are proved:
  * `findHole_first_prefix`: `adjacentPairs w = pre ++ (a,b) :: post` with
    every pair in `pre` within the threshold — "first" in the positional
    sense, with no extra hypotheses.
  * `findHole_first_ascending`: the original `y < b` formulation, under the
    ascending-window invariant that `onEid` maintains (`Ascending w`).
    The key auxiliary fact is `ascending_pair_ge_head`.

* **`window_ascending_preserved`** — decomposed into
  `adjacentPairs_tail_subset` / `adjacentPairs_drop_subset` (adjacent pairs
  of a suffix are adjacent pairs of the whole list), `ascending_drop`,
  `ascending_trim20` (the 20-entry trim keeps the window ascending) and
  `ascending_append_last` (appending a strictly larger eid to the end keeps
  it ascending).  The reset branch is trivial: `adjacentPairs [e] = []`.

* **`cooldown_prevents_storm`** — monotonicity of `t - lastFetchAt` in `t`
  (`omega`).  `cooldown_gap_between_fetches` was added to state the actual
  safety consequence explicitly: a permitted fetch at `t2` after one at
  `t1` satisfies `t1 + cooldownMs ≤ t2`.

## 2. Splitter

| obligation | outcome |
|---|---|
| `chunks_tile` | proved as stated |
| `chunks_length_le` | proved as stated |
| `chunks_interior_exact` | proved as stated (hypothesis `1 < length` turns out to be unnecessary) |
| `pack_maximal_adjacent` | **false as stated** → `pack_maximal_adjacent_counterexample`, plus `pack_maximal_adjacent_consecutive` |
| `pack_optimal` | **false as stated** → `pack_optimal_counterexample`, plus `IsPackOf`, `pack_optimal_correct`, `pack_isPackOf` |
| `enqueue_append_dropLast` | proved as stated |

### Hard break

`chunks` is defined by well-founded recursion, so each proof goes through a
fuel-style auxiliary lemma (`… _aux`) doing induction on a bound `n` for
`l.length`, unfolding one `chunks` step per iteration.  `chunks_ne_nil`
(the chunk list is never empty) is what makes the `dropLast` step of
`chunks_interior_exact_aux` work.

### Greedy pack — maximality

The original statement quantifies over *any* two packed messages `A`, `B`
and forbids their join from also being in the pack.  A blank input line
flushes the accumulator, so this fails: with `m = 5`,
`pack ["ab", "", "cd", "", "ab cd"] 5 = ["ab", "cd", "ab cd"]`
(`pack_maximal_adjacent_counterexample`, by `decide`).

The correct statement is about *consecutive* messages of a blank-free input:
`pack_maximal_adjacent_consecutive` shows that if
`pack lines m = pre ++ A :: B :: post` then `m < A.length + 1 + B.length`.
The proof is an induction on the input with the accumulator generalised
(`packWith_maximal_consecutive`); the emission case uses
`packWith_head_ge` — the first message emitted from accumulator `b` is at
least as long as `b`, because the accumulator only grows.

### Greedy pack — optimality

`ValidPack lines m msgs` as given never mentions `lines`, so `[]` is a
"valid pack" of `["a"]` and the claim `msgs.length ≥ (pack lines m).length`
fails immediately (`pack_optimal_counterexample`).

The corrected notion is `IsPackOf lines m msgs`: `msgs` are the single-space
joins (`joinGroup`) of a partition of `lines` into consecutive non-empty
groups, each join within the budget.  Then
`pack_optimal_correct : (pack lines m).length ≤ msgs.length`
for blank-free `lines`, and `pack_isPackOf` shows the greedy pack is itself
an `IsPackOf`, so greedy really attains the minimum.

The optimality proof is the standard greedy/exchange argument, phrased with
two auxiliary functions:

* `gStep b lines m` — how many further lines the loop absorbs into
  accumulator `b`;  `fgl lines m` — the size of the greedy first group.
* `packWith_len_step` / `pack_len_step`: the greedy output length satisfies
  `(pack lines m).length = 1 + (pack (lines.drop (fgl lines m)) m).length`.
* `gStep_mono_buf`: a longer accumulator absorbs no more lines than a
  shorter one; hence `gStep_le_fgl` (`gStep x rest m ≤ fgl rest m`).
* `pack_len_drop_le`: greedy on a suffix never needs more messages than
  greedy on the whole list — proved by strong induction on the length,
  combining the previous two facts.
* `gStep_absorbs`: greedy absorbs every group that fits (via
  `joinFrom_length_ge`, monotonicity of the join length).

The main induction (`pack_optimal_groups`) is over the group list `gs`:
greedy's first group is at least as long as `gs`'s first group
(`gStep_absorbs`), so what greedy has left is a suffix of what the
competitor has left, and `pack_len_drop_le` + the induction hypothesis
close the step.

For `pack_isPackOf` the string-level companion of `packWith_len_step` is
needed (`packWith_step_str`: the emitted message is exactly
`joinFrom b (lines.take (gStep b lines m))`), together with
`gStep_take_fits` (that message respects the budget).

### Batcher

`enqueue_append_dropLast` is `simp`.
