import Lake
open Lake DSL

package IrcFiberFormal where

/-- The formal development for Smart-detail glyph selection and 512-byte
compression.  Lives under `frontend/wasm-img2irc/lean/` next to the WASM
encoder it specifies. -/
@[default_target]
lean_lib GlyphSmart where
  srcDir := "frontend/wasm-img2irc/lean"
  roots := #[`GlyphSmart]

@[default_target]
lean_lib IrcFiber where
  globs := #[.submodules `IrcFiber]
