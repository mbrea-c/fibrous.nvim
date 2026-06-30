# Open Tasks & Issues

## Bugs

- [x] Relayout (e.g. resize) clears visual selection
  - Fixed: neutralized nui's cursor-wiggle relayout workaround (no window switch / cursor move on relayout). Pinned by `tests/mount/relayout_preserves_mode_spec.lua`.
- Split pane synchronization issues
  - [ ] When mounted on a pane, closing the floats with `:q` leaves the pane open

## Website / WASM playground (`website_design.md`)

A fullscreen, client-side Neovim (WASM) homepage whose UI is built natively in
nui-reactive. Three decoupled tiers: this library (Lua) → WASM Neovim engine →
docs SPA.

### Tier 2 — `nvim-wasm-core` (C/WASM Neovim engine)

- [ ] Compile upstream Neovim to WASM via Emscripten → `nvim.wasm` + `nvim.js`
- [ ] Mock OS filesystem in memory; patch platform abstractions (libuv async I/O) for the browser sandbox
- [ ] `nvim-wasm-core/flake.nix`: devShell (emscripten/cmake/ninja/node) + package build with writeable `EM_CACHE`

### Tier 3 — `nvim-react-docs` (web SPA)

- [ ] Build script (Node): scan `nvim-react` repo, map every `.lua` → `LUA_VIRTUAL_FS` JSON, emit `lua_bundle.js`
- [ ] Runtime bootstrap: load `lua_bundle.js` + `nvim.js`, populate Emscripten VFS (`FS.mkdirTree`/`writeFile`), `callMain()`
- [ ] Minimalist SPA shell (no Next/Astro): `index.html` + `styles.css` + `app.js` + `xterm.js` terminal container
- [ ] `nvim-react-docs/flake.nix`: devShell (node, live-server) + package build (`node build.js`) → static `public/`

### UI demos (built in nui-reactive, run inside the WASM instance)

- [ ] Interactive counter: source-code pane (left) + live rendering button (right) responding to keyboard/mouse
- [ ] DevTools reconciliation inspector: togglable overlay of the live VDOM tree with re-render flash highlights

### Mobile / UX & risk mitigations

- [ ] Tap→click: map touch coords to terminal grid, dispatch native mouse press/release (`mouse=a`)
- [ ] Gestural scroll: `touchmove` deltas → `<ScrollWheelUp/Down>` packets past a threshold
- [ ] Loading indicator: DOM/CSS progress UI for the multi-MB engine download (bounce mitigation)
- [ ] Keyboard-theft mitigation: design navigation around Vim primitives (leader, arrows, buffer-local hotkeys) — avoid browser-reserved `Ctrl+W`/`Ctrl+N`
- [ ] Viewport stabilization CSS: `touch-action: none`, `user-select: none` on the nvim container
