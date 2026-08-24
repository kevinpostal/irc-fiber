import Lake
open Lake DSL

-- IRC Fiber formalization project (Aristotle targets).
-- Deliberately dependency-free (core Lean only) so `lake build` is fast
-- and offline; the Aristotle SDK resolves mathlib imports itself when a
-- project needs them (docs/aristotle/README.md).
package IrcFiberFormal where
  -- no dependencies

lean_lib IrcFiber
