# Open Tasks & Issues

## Project

- [x] Name the project `fibrous.nvim` (repo) / `fibrous` (Lua module)
  - Renamed `lua/nui-reactive/` → `lua/fibrous/`, all `require("nui-reactive…")` → `require("fibrous…")`, augroups `NuiReactive*` → `Fibrous*`, `vim.g.nui_reactive_example` → `vim.g.fibrous_example`, README/flake/design docs, and `nvim-react` → `fibrous` in `website_design.md`. Suite green (41 passed).
  - [ ] Rename the on-disk repo directory `nui-reactive/` → `fibrous.nvim/` (left to you — renaming the live working dir mid-session would break the cwd)

## Bugs

- [x] Relayout (e.g. resize) clears visual selection
  - Fixed: neutralized nui's cursor-wiggle relayout workaround (no window switch / cursor move on relayout). Was pinned by `tests/mount/relayout_preserves_mode_spec.lua` (deleted with the nui host, 2026-07-03).
- Split pane synchronization issues
  - [x] When mounted on a pane, closing the floats with `:q` leaves the pane open — resolved by the inline mount (`wire()`'s WinClosed on the root float closes the pane in `on_teardown`); pinned 2026-07-03 by the mount_spec test ":q on the root float tears down the app AND its pane".
- [x] Pre-existing suite failures (2, nui-host relayout specs; confirmed on a clean
  tree 2026-07-02, unrelated to the inline host work):
  `relayout_no_sync_redraw_spec` (expected 0 redraws, got 4) and
  `relayout_preserves_mode_spec` (visual mode dropped to normal) — likely an
  nvim-version behavior change; both guarded the old nui host and were deleted
  with it (task 9 migration, 2026-07-03). Suite fully green since.

## Website / WASM playground (`website_design.md`)

A fullscreen, client-side Neovim (WASM) homepage whose UI is built natively in
fibrous. Three decoupled tiers: this library (Lua) → WASM Neovim engine →
docs SPA.

### Tier 2 — Neovim-in-WASM engine (`../nvim-wasm-core`, separate repo)

**Decision (2026-06-30):** build our **own** MIT-licensed Neovim→WASM wrapper.
Rationale: we need a Nix-flake build regardless, and no viable existing
artifact exists with a license that permits redistribution.

Target architecture (supersedes the Emscripten sketch in
`design.md §2.2/§4.1` — chosen because it needs **no SharedArrayBuffer / no
COOP-COEP headers** → plain static edge hosting):
- Compile upstream Neovim as **wasm32-wasi** via **wasi-sdk** (clang), not Emscripten.
- Run the Binaryen **Asyncify** pass (`wasm-opt --asyncify`) so the synchronous
  WASI event loop can yield to the browser without threads.
- Browser side: **`@bjorn3/browser_wasi_shim`** provides the WASI imports; the
  Neovim `$VIMRUNTIME` ships as an **`fflate`**-compressed tarball unpacked into
  the in-memory WASI FS.
- Drive the UI over Neovim's **msgpack-RPC** (`--embed`) → frontend grid.

Incremental build plan (each step has a runnable smoke check under headless
`wasmtime` in CI before moving on):
- [x] Scaffold `../nvim-wasm-core` (own repo, MIT) with its own `flake.nix`: devShell + checks using nixpkgs `pkgsCross.wasi32` clang toolchain + `binaryen` + `wasmtime` + `cmake`/`ninja`/`pkg-config`. (No bundled `wasi-sdk` in nixpkgs; `pkgsCross.wasi32` gives a `wasm32-unknown-wasi` clang wrapper, which is cleaner. `uvwasi` available for the libuv→WASI layer.)
- [x] Spike 0 — compile `spike/hello.c` → `hello.wasm` via the cross stdenv; `checks.hello-runs` runs it under `wasmtime` in the build sandbox and asserts output. `nix flake check` GREEN.
- [x] Map Neovim's build deps for wasm32-wasi. **Empirical result (2026-06-30)** using `nixpkgs#pkgsCross.wasi32.*` (needs `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 --impure`):
  - ✅ **Build clean:** `utf8proc`, `msgpack-c` (pure C, no terminal/syscall deps).
  - ❌ **`libuv`** — source won't compile (`unix/core.c`, `fs.c`, `inet.c`): nixpkgs has **no WASI port** of libuv. This is THE linchpin — Neovim's whole event loop is libuv. Needs a WASI-patched libuv. `uvwasi` in nixpkgs is the *inverse* (WASI-on-libuv for runtimes), not what we need.
  - ❌ **terminal stack** (`libvterm`, `unibilium`, `libtermkey`) + **`readline`→`ncurses`** — ncurses fails configure's link conftest under wasi (suspect the `-Wl,--undefined-version` LDFLAG, which `wasm-ld` rejects). This chain is the TUI we *don't* want for an `--embed`/RPC build, so the move is to drop/stub it, not fix it.
  - ❌ **`tree-sitter`** (Rust) — cc-wrapper passes `--target wasm32-wasip1 != wasm32-unknown-wasi`; multi-target wrapper mismatch. Needs an unwrapped compiler or triple alignment.
  - Conclusion: `nix build pkgsCross.wasi32.neovim` is **not** viable as-is; nixpkgs wasi32 is useful only as a *parts bin* for the easy leaf libs. Strategy = hand-rolled derivation (nixpkgs leaf libs where they work + our patched libuv + PUC Lua + TUI stripped).
- [x] **Linchpin: WASI libuv — DONE (2026-06-30).** `../nvim-wasm-core/pkgs/libuv-wasi` builds a real `libuv.a` for wasm32-wasi, wired into the flake as `packages.libuv-wasi` + green check `checks.libuv-loop-runs` (a `uv_timer` program ticks 3× under wasmtime and the loop exits). **Architecture pivot away from the patch-real-libuv plan below:** real-libuv-on-WASI is a dead end — wasi-libc gates the *entire* sigset/sigaction masking API (sigemptyset/sigaddset/sigprocmask/sigaction/`struct sigaction`/`sigset_t`) behind the never-defined `__wasilibc_unmodified_upstream`, and `_WASI_EMULATED_SIGNAL` does **not** expose it (only ungates the header + `signal()`/`raise()`). `posix-poll.c`/`signal.c` therefore can't compile. So we **replace the library**: keep libuv's public headers, compile a single self-written `pkgs/libuv-wasi/stub.c` that reimplements the public API (userspace loop: timers/idle/prepare/check/async/close + real WASI fs ops; ENOSYS for net/process/tty/signal/thread). `default.nix` patches `include/uv/unix.h` (drop absent `netdb.h`/`termios.h`/`pwd.h` on `__wasi__`, add a `#include "uv/posix.h"` platform branch, strip `struct termios` from `UV_TTY_PRIVATE_FIELDS`), compiles stub.c with `-D_WASI_EMULATED_SIGNAL`, `ar`s `libuv.a`. **Consumers of these headers must compile `-D_WASI_EMULATED_SIGNAL` and link `-lwasi-emulated-signal`** (uv.h → signal.h is an `#error` otherwise); Neovim will do the same. stub.c is reference-clean (own implementation; no upstream backend source). Remaining `uv_*` symbols (tcp/pipe/tty/process/signal/thread/dns) get added to stub.c on demand when the Neovim link surfaces exactly which are referenced.
  - ~~Confirmed there is **no upstream libuv WASI platform** and **no license-clean drop-in** — porting is unavoidable engineering (add a libuv `wasi` platform / stub the unix syscall files). Everything else is downstream of this.~~ (Superseded by the stub.c approach above — the "patch the real unix backend" framing was wrong; the signal wall makes it unworkable.)
  - **DECISION (2026-06-30): toolchain = (A) nixpkgs `pkgsCross.wasi32`.** Spiked both: nixpkgs libuv *configures cleanly* for `--host=wasm32-unknown-wasi` and compiles until it hits missing headers — first `netdb.h`, then `termios.h`. Stubbing `netdb.h` advanced the build (confirms the gaps are headers, not the toolchain). Crucially, the missing headers (`netdb.h`, `termios.h`, `pwd.h`, `net/if.h`) are absent from wasi-libc **by WASI design** (no DNS / terminals / user-db / netif), so **wasi-sdk 29 lacks them too** → the toolchains are equivalent for the libuv port. Chose A for hermetic reproducibility (clang 21 / wasilibc 27, already in our flake, Spike 0 green). Add `-fwasm-exceptions` where C++ EH is needed (clang 21 supports it). Spike artifacts: `scratchpad/libuv-spike.nix`.
- [x] **libuv wasi implementation — DONE via stub.c (see linchpin item above).** Superseded the "build libuv's real unix backend + shim headers" plan: instead of compiling `core.c`/`fs.c`/`posix-poll.c`/etc., `pkgs/libuv-wasi/stub.c` reimplements the public API directly (loop+timers+idle+async+fs real; net/tty/process/signal/thread = ENOSYS). No shim headers needed — the unix.h patch drops the 3 absent headers, and every other POSIX header libuv wants (`sys/socket.h`, `netinet/*`, `arpa/inet.h`, `sys/param.h`, `pthread.h`, `semaphore.h`, `signal.h`) is present in wasi-libc 27. The 4 shim-header files (`netdb.h`/`termios.h`/`pwd.h`/`net/if.h`) and the `wasi_socket_ext.h` force-include were deleted.
  - ~~**Port surface mapped (2026-06-30 spike, `make -k`):** with the 4 shim headers in place, all remaining compile errors live in the networking + tty backends only…~~ (Obsolete: that spike was against the abandoned real-backend approach. The signal-masking wall — not sockets/tty — is what actually killed it; stub.c sidesteps the whole thing.)
- [~] Cross-compile remaining Neovim deps for wasm32-wasi. **PUC Lua 5.1 — DONE (2026-07-01):** `../nvim-wasm-core/pkgs/lua51-wasi` builds `liblua.a` (strict `-DLUA_ANSI`, no readline; nixpkgs' lua5_1 can't cross — pulls readline which wasm-ld rejects). Wired as `packages.lua51-wasi` + green check `checks.lua-embed-runs` (embed Lua, run `for`-loop + `string.format` script → `sum=55 lua=Lua 5.1` under wasmtime). Two WASI-isms solved and **reusable for every C dep below (luv, tree-sitter, nvim itself):**
    1. **setjmp/longjmp → wasm EH.** wasi-libc's `<setjmp.h>` is an `#error` unless you compile with `-mllvm -wasm-enable-sjlj` and link `-lsetjmp`. That lowering emits *legacy* EH `try`, which wasmtime 45 rejects; post-process the **final linked module** with `wasm-opt --emit-exnref -all` (binaryen, already in flake) and run `wasmtime -W exceptions=y`. Any dep using setjmp (Lua's error handling does) inherits this whole pipeline.
    2. **Missing libc fns.** wasi-libc *declares* but doesn't *implement* `system`/`tmpnam`/`tmpfile`/`clock` (no process spawn / temp files / process clock; `-lwasi-emulated-process-clocks` only ships `times`, not `clock`). `pkgs/lua51-wasi/wasi_compat.c` bakes failing stubs into the archive (clock → real monotonic impl). Also `-DL_tmpnam=260` (macro absent). Consumers just link `-llua -lsetjmp -lm`.
  - **AUTHORITATIVE DEP MAP (2026-07-01, top-down probe of nixpkgs neovim 0.12.3 = our target).** Extracted from `src/nvim/CMakeLists.txt` `find_package` calls + `cmake.deps/deps.txt`. Our libuv-wasi (1.52.1) and lua51-wasi (5.1.5) **exactly match Neovim 0.12.3's pins** (it wants libuv ≥1.28, Lua 5.1 EXACT). Nvim also pins luv `1.52.1-0`, lpeg `1.1.0`, lua-compat-5.3 `v0.13`, utf8proc `v2.11.3`, tree-sitter `v0.26.7`.
    - **External REQUIRED link deps.** ✅ **`luv` — DONE (2026-07-01):** `pkgs/luv-wasi` builds `libluv.a` from nixpkgs' luv `1.52.1-0` (exactly nvim's pin; single-TU amalgamation + bundled lua-compat-5.3). Wired as `packages.luv-wasi` + green **integration check `checks.luv-runs`**: a Lua script drives `uv.new_timer` end-to-end (lua51-wasi + luv + libuv-wasi) → ticks 3× under wasmtime. This forced **completing libuv-wasi's public symbol surface**: luv references 258 `uv_*`; stub.c had 68; the other **190 are now `pkgs/libuv-wasi/stub_ext.c`** (generated by `gen_stubs.py` from uv.h — type-correct, mostly `UV_ENOSYS` for sockets/subprocess/TTY/thread/DNS, with single-threaded no-op-success sync primitives: mutex/once/key/sem). luv needed two small WASI shims: `pkgs/luv-wasi/shims/netdb.h` (absent header — struct addrinfo/protoent + AI_/NI_ constants) force-included via `shims/wasi_compat.h`, and `wasi_stub.c` (getprotoby*/get·setuid/gid stubs). Consumers link `-lluv -llua -luv -lsetjmp -lwasi-emulated-signal -lwasi-emulated-getpid -lm`. ✅ **`utf8proc` + `lpeg` — DONE (2026-07-01):** `pkgs/utf8proc-wasi` (v2.11.3, nvim's exact pin — self-contained 2-file C, `-DUTF8PROC_STATIC`) and `pkgs/lpeg-wasi` (v1.1.0, exact pin — 6 plain-C TUs incl. `lpcset.c`, links lua51-wasi headers only). **Both needed ZERO WASI shims** — pure C, no OS deps, as predicted. Green checks `checks.utf8proc-runs` (case-fold + NFC under wasmtime, no Lua) and `checks.lpeg-runs` (digit grammar inside Lua). ✅ **`tree-sitter` — DONE (2026-07-01):** `pkgs/tree-sitter-wasi` builds the runtime from nixpkgs' v0.26.8 (nvim pins 0.26.7; ≥0.25 required — satisfied) as a single amalgamation `lib/src/lib.c`, `-I lib/include -I lib/src`, **no `TREE_SITTER_FEATURE_WASM`** (that feature embeds wasmtime to run grammars-as-wasm — can't nest; `wasm_store.c` compiles to nothing without it). **Zero WASI shims** — plain C99. Green check `checks.tree-sitter-runs` (parser lifecycle + ABI=15 under wasmtime). Grammars (tree-sitter-c/lua/vim/…) are separate generated parsers compiled into nvim later, not a runtime dep. ✅ **`iconv` — DONE (2026-07-01), needs NOTHING from us:** wasi-libc 27 already ships a real iconv (`iconv.h` in the sysroot + `iconv`/`iconv_open`/`iconv_close` in `libc.a`, musl-derived ~500-byte impl). Verified under wasmtime: ISO-8859-1 `é`(0xE9) → UTF-8 (0xC3 0xA9), rc=0. Neovim's `FindIconv` only *requires* the header (`ICONV_LIBRARY` is optional) → it'll resolve from the sysroot with no flags. **The reference shimmed iconv only because their wasi-sdk 29 lacked it; our wasi-libc 27 has it.** lua-compat-5.3 is already vendored inside luv (and nvim bundles its own copy too).
  - 🎯 **ALL external REQUIRED Neovim deps are now satisfied** (libuv ✅ Lua ✅ luv ✅ lpeg ✅ utf8proc ✅ tree-sitter ✅ iconv ✅-in-libc). 6 green wasmtime checks. **The dependency wall — the item this doc called "the linchpin" — is cleared.** Next: write the CMake wasi32 cross-toolchain file and attempt the actual `nvim.wasm` configure/build against these artifacts (with `-DPREFER_LUA=ON -DENABLE_WASMTIME=OFF -DENABLE_UNIBILIUM=OFF -DENABLE_LIBINTL=OFF`), then work the nvim-level shims (signal/pty/stdio-RPC) + Asyncify per the reference's `wasi-shim/` + `asyncify/`.
    - **Optional deps to DISABLE (drops them entirely):** `-DENABLE_WASMTIME=OFF` (nvim 0.12 can embed wasmtime 36 to run tree-sitter grammars-as-wasm — we obviously can't nest a Rust wasm runtime; disable), `-DENABLE_UNIBILIUM=OFF` (terminfo/TUI), `-DENABLE_LIBINTL=OFF` (i18n/gettext). Set `-DPREFER_LUA=ON` to select PUC Lua 5.1 over LuaJIT.
    - **NOT external deps — vendored in the nvim source tree, compile as part of nvim.wasm:** `msgpack` (→ `src/mpack/`, nvim's own mpack), `libvterm` (→ `src/nvim/vterm/`), `libtermkey` (→ `src/nvim/tui/termkey/`). **This kills the old "TUI terminal stack" worry** — vterm/termkey/mpack need no separate derivation; they build with nvim (the open question is only whether they *run* headless, not whether they link).
    - Deferred: the actual CMake cross-toolchain file (wasi32 clang) — write it once the REQUIRED external deps above exist; a full cross-configure now would just fail on missing deps.
- [x] **Build `nvim.wasm` — DONE (2026-07-01).** Upstream Neovim 0.12.3 (`neovim-unwrapped.src`, PUC Lua 5.1) cross-compiles and **runs under wasmtime**: `--version` banner ✅, headless `+q` clean exit ✅, `:lua` eval (`vim.fn`/`vim.api`) ✅, full buffer edit + `:wq` round-trip through the WASI fs ✅. Packaged as `packages.nvim-wasi` (`pkgs/nvim-wasi/`) + check `checks.nvim-runs`; output = `nvim.wasm` (~12.8MB, RelWithDebInfo) + `runtime/` tree. Run: `wasmtime run -W exceptions=y --dir runtime::/runtime --env VIMRUNTIME=/runtime nvim.wasm`. Key findings:
  - **No build-system patching needed for codegen:** Neovim's own cross hook (`NLUA0_HOST_PRG` + `LUA_GEN_PRG`, src/nvim/CMakeLists.txt) runs all code generation with a host lua + host-built `nlua0.so` → `pkgs/nvim-wasi/nlua0.nix` (native derivation), consumed by the cross configure. Two-stage build proven end-to-end.
  - **Toolchain:** `pkgs/nvim-wasi/toolchain-wasi.cmake` (`CMAKE_SYSTEM_NAME=WASI`, env-driven `WASI_SHIM_DIR`/`WASI_COMPAT_H`/`WASI_SHIM_OBJ`). Gotcha ×2: `CMAKE_FIND_ROOT_PATH` only re-roots — prefixes must ALSO be in `CMAKE_PREFIX_PATH` (hit for wasi libs and sysroot iconv).
  - **nvim-level WASI shims (`pkgs/nvim-wasi/`):** `shims/netdb.h` + `shims/termios.h` (headers absent from wasi-libc, `-idirafter`); `shims/wasi_nvim_compat.h` force-included everywhere (struct winsize, SIG_SETMASK consts, dup/dup2/umask/pthread_exit decls, F_DUPFD_CLOEXEC); `shim.c` (no-op bodies: termios/sigmask/tcdrain; dup/dup2→ENOSYS, umask→022, pthread_exit→_exit); `pty_proc_unix.c` whole-TU replacement (forkpty/grantpt unshimmable → `:terminal` spawn = ENOSYS; same path so `*.c.generated.h` codegen applies — done via `postPatch` cp).
  - **libuv stub grew real env/cwd support:** `uv_os_getenv/setenv/unsetenv/environ/homedir/tmpdir/get_passwd`, `uv_cwd`/`uv_chdir` now real (wasi-libc backs getenv/environ; getcwd/chdir emulated userspace) + `uv_dl*` (dlopen→error) and `uv_mutex_init_recursive`. NOTE: `stub_ext.c` is now hand-curated — merge, don't overwrite, when regenerating with gen_stubs.py.
  - Same sjlj pipeline as every Lua artifact: `-mllvm -wasm-enable-sjlj` → `wasm-opt --emit-exnref -all` → `wasmtime -W exceptions=y`.
- [x] **First browser boot — DONE (2026-07-01).** `nix run .#nvimwasm` serves `packages.nvim-wasm-web` (web/ page + @bjorn3/browser_wasi_shim 0.4.2 + $VIMRUNTIME as tar.gz unpacked via DecompressionStream into the shim's in-memory FS) and opens Firefox in kiosk (fullscreen) mode; nvim.wasm runs `--version` + a headless Lua API demo (vim.version, buffer round-trip, file write/read through the WASI fs) streaming to the page. Batch-style only — interactive editing still needs Asyncify. Browser-vs-wasmtime landmines found: (1) wasi-libc `access()` checks WASI rights bits which browser_wasi_shim zeroes → all files "unreadable" → libuv stub's `uv_fs_access` now stat()-based; (2) the shim's per-syscall debug logging is ON by default (+ nvim writes stderr byte-at-a-time) → must pass `{debug:false}`; (3) a modified listed buffer makes `:q` wait for input forever (no interactive stdin) → demos must use scratch buffers + `:qa!`.
- [x] **Interactive Neovim UI in the browser — DONE (2026-07-02).** Architecture: **`nvim --embed` (msgpack-RPC server on stdin/stdout) + a JS UI client** (canvas ext_linegrid renderer), i.e. the same client/server split every GUI (Neovide etc.) uses. Verified end-to-end three ways: wasmtime pipe test (attach → full first frame → `:qa!` exit 0), node replica of the browser boot path (sync scripted poll driver, PASS), and node with real JSPI (`--experimental-wasm-jspi`: typed text into a buffer via `nvim_input`, quit cleanly, PASS). Key decisions/findings:
  - **Asyncify is dead, JSPI replaces it:** binaryen's Asyncify pass crashes on wasm-EH modules (`UNREACHABLE at Flatten.cpp:231`) and our sjlj pipeline requires EH. Instead the one blocking import, `poll_oneoff`, is wrapped in **`WebAssembly.Suspending`** and `_start` driven via **`WebAssembly.promising`** (JSPI — shipped by default in Firefox 152+ and Chrome 137+; **Firefox 151 and earlier need `about:config` → `javascript.options.wasm_js_promise_integration = true`**, verified working on 151.0b9; no COOP/COEP, static hosting preserved). Non-JSPI browsers fall back to the old batch demo — note the batch headless step is known to hang/spin on Firefox (shim's busy-wait poll_oneoff), so on Firefox the pref is effectively required.
  - **In-process TUI is impossible by design:** nvim 0.10+ spawns *itself* as a child `--embed` server for the builtin TUI (`main.c` `ui_client_start_server`) — no process spawn under WASI. `--embed` + external UI is the only interactive shape, and the protocol-native one anyway.
  - **libuv-wasi stub grew a real stream layer** (`pkgs/libuv-wasi/stub.c`): fd-backed pipe/tty streams (`uv_pipe_*`/`uv_tty_*`/`uv_read_start`/`uv_write`…), reads driven by `poll(2)` inside `uv_run` (wasi-libc lowers poll → poll_oneoff → JSPI-suspendable), writes synchronous with libuv-contract deferred callbacks; blocking-poll-then-break semantics so UV_RUN_ONCE drains nvim's multiqueue (deadlock otherwise). 18 stream symbols deleted from `stub_ext.c` (still hand-curated — merge, never regenerate over it).
  - **channel.c patch** (nvim-wasi postPatch): embedded stdio channel re-homes fds via `fcntl(F_DUPFD_CLOEXEC)`+`dup2` (both absent on WASI) → keep the RPC channel on fds 0/1.
  - **Web client** (`web/`): self-written `msgpack.js` (streaming codec), `nvim_io.js` (stdin/stdout character-device Fds + real poll_oneoff — the shim's builtin only handles a single clock sub and busy-waits, and never writes `nevents`), `renderer.js` (canvas ext_linegrid grid: hl attrs, scroll, cursor shapes via mode_info), `keys.js` (KeyboardEvent → `nvim_input` key-notation). `nix run .#nvimwasm` now boots straight into an editable Neovim.
  - Landmine (bit us TWICE): pages cached before the server sent `Cache-Control: no-store` are heuristically fresh for years (nix mtime 1970) and Firefox kept executing a months-old main.js (visible as `runNvim@main.js` frames + `wasi:` debug spam — functions that no longer exist). Fixed for good: server sends no-store AND the default port moved 8397 → 8402 (new origin = clean cache); main.js banner now prints a build tag so staleness is obvious.
- [x] **Nix consumer API + graceful degradation — DONE (2026-07-02).**
  - **`lib.<system>.mkNvimWasmWeb { initLua, plugins, font = {family,px}, env, extraXdg }`** (pkgs/nvim-wasm-web, `lib.makeOverridable`; `packages.nvim-wasm-web = mkNvimWasmWeb { }`). Plugins/init.lua ship as `config.tar.gz` mounted at `/xdg` (`XDG_CONFIG_HOME=/xdg/config`, `XDG_DATA_HOME=/xdg/data`, plugins under `data/nvim/site/pack/web/start/*`); font+env flow via `config.json`. Writable state stays under `HOME=/work`. Verified end-to-end (node test asserts init.lua text, plugin text, and env marker all render in the grid; Chromium screenshot confirms font px). This IS the Tier-2→Tier-3 artifact interface. README documents it.
  - **No-JSPI browsers no longer lock up**: the page shows what's missing + exact instructions (Firefox 139–151 pref name, versions that work OOTB) and runs only a safe `nvim --version` proof-of-life (the old headless demo busy-spun the tab via the shim's poll_oneoff). Verified by Firefox screenshot without the pref.
  - **Bug found & fixed on the way: the entire uv_fs scandir family was ENOSYS** (stub_ext.c) — `vim.fn.readdir`, `globpath`, and **pack/\*/start plugin discovery silently found nothing**, under wasmtime too. Implemented `uv_fs_scandir/_next`, `uv_fs_opendir/readdir/closedir` for real in pkgs/libuv-wasi/stub.c (wasi-libc readdir(3); state freed via `uv_fs_req_cleanup`). `vim.fs.dir`/plugin loading now work everywhere.
- [ ] Mouse support in the web client (`nvim_input_mouse`: click/drag/wheel → grid coords) — keyboard-only today.
- [ ] Revisit `$VIMRUNTIME`/config tarball size & lazy-loading (works today via DecompressionStream; ~unoptimized).

### Tier 3 — `fibrous-docs` (static site, `../fibrous-docs`)

- [x] **Site scaffold — DONE (2026-07-02).** The old Emscripten-era plan (lua_bundle.js / VFS JSON / xterm.js) is obsolete — Tier 2's `mkNvimWasmWeb` already does all of it. `../fibrous-docs` is now: `flake.nix` (packages.site = `mkNvimWasmWeb { plugins = [ fibrous ]; initLua = ./site/init.lua; font.px = 17; }` — the fibrous repo with vendored nui ships as a pack/start plugin), `site/init.lua` (VimEnter: dofile the repo's examples/init.lua for :Example/:Examples, then mount a fibrous-rendered welcome panel; note pack plugins are NOT on rtp during init.lua — defer everything), `nix run` local server (port 8410), README, MIT LICENSE.
  - **Verified end-to-end in node**: welcome panel renders → `q` + `:Example counter` → `+++` → `Count: 3` → `-` → `Count: 2` → `:qa!` exit 0. use_state/use_effect/keymaps/nui popups all work inside nvim.wasm. Chromium screenshot confirms the browser rendering. Testing lesson: **ext_linegrid sends delta cells** — asserting on a concatenated grid_line stream misses re-renders (only the changed digit is sent); tests must maintain a real 2D grid model.
- [x] **GitHub Pages — DONE (workflow) / BLOCKED (activation).** `.github/workflows/pages.yml`: nix build .#site → upload-pages-artifact → deploy-pages on push to main. Static hosting is sufficient (no COOP/COEP needed — JSPI, not SharedArrayBuffer). **Before CI can build**: publish nvim-wasm-core + fibrous.nvim to GitHub and switch fibrous-docs' flake inputs from `path:/home/manuel/src/...` (local-dev only; relative path inputs can't escape the flake root) to `github:` URLs — TODO markers in flake.nix; also set repo Settings → Pages → Source: GitHub Actions.


### UI demos (built in fibrous, run inside the WASM instance)

- [ ] Interactive counter: source-code pane (left) + live rendering button (right) responding to keyboard/mouse
- [ ] DevTools reconciliation inspector: togglable overlay of the live VDOM tree with re-render flash highlights

### Mobile / UX & risk mitigations

- [ ] Tap→click: map touch coords to terminal grid, dispatch native mouse press/release (`mouse=a`)
- [ ] Gestural scroll: `touchmove` deltas → `<ScrollWheelUp/Down>` packets past a threshold
- [ ] Loading indicator: DOM/CSS progress UI for the multi-MB engine download (bounce mitigation)
- [ ] Keyboard-theft mitigation: design navigation around Vim primitives (leader, arrows, buffer-local hotkeys) — avoid browser-reserved `Ctrl+W`/`Ctrl+N`
- [ ] Viewport stabilization CSS: `touch-action: none`, `user-select: none` on the nvim container

### IMPORTANT: NEW UI HOST
The current nui-host is insufficient for a web application (and also not great
as a neovim UI host). We need a new UI host that truly feels "neovim-native", satisfying the following:

* Layouts render _inline_ into the parent buffer; that is, layouts don't automatically
  create new float windows.
* Most components also render directly into the parent buffer:
  * e.g. Buttons, checkboxes, text labels and paragraphs can render inline into
    the parent buffer via text and extmarks (which ought to be ummodifiable)
  * Exceptions are for example:
    * a dedicated "raw buffer" component that renders a subbuffer
      in a float (like components do in nui-host) and gives control of the buffer
      to the user, 
    * Any text input elements need their own buffer as they do right now
* Components should support a "box model" like in css:
  * Border, inner margins, outer margins. Each should be configurable "per
    direction" if needed (i.e. border only on left and right with specific
    characters, no borders up and down)
  * Highlights on hover and such are desirable. The vim cursor determines the hover
    and "click"/interaction (e.g. with checkboxes and buttons)
* Mouse integration is a plus (can be a follow-up task if complicated)
* Native vim buffer scrolling is respected and leveraged to make the UI "feel" native. Since most components are 
  rendered inline, they scroll naturally.
  * For "subbufer" type components, they act as if they occupied a space in the
    parent buffer, and scroll accordingly (their floats move when the parent
    buffer is scrolled). They need to support partial and full occlusion
* Native cursor motions are respected and the primary way of navigating.
  * <C-w>-hjkl when focused in a subbufer will move the focus to either the parent buffer
  * hjkl (and other motions like <C-u>/<C-d>) in normal mode in a subbuffer navigates within the
    buffer as expected, unless the motion would bring the cursor to a parent
    buffer (i.e. if the cursor is already at the "end" of the buffer in the
    given direction), in which case they move to the buffer that exists in that
    direction. When in a parent buffer, navigating to a position in the buffer
    occupied by a mounted subbuffer will move the focus onto that subbuffer.
  * ...and so on. Essentially the UI should "feel" native.
* Obviously this means we'll need to do our own layouting. Let's keep it
  relatively simple but powerful. We need composable row/column layouts, with
  align/justify support, and box-model support as I previously specified. We can
  discuss this further if more details are needed.
  * Very open to discussion on this, but I think we'd need a two-pass layouting:
    * Bottom-up "measure()" pass
    * Top-down "layout()" pass
* Example. Suppose our component tree has these components:
  ```
  Rows
    Columns
      label
      checkbox
      checkbox
    TextInput
  ```
  And we're mounted on a split pane. Then the only physical neovim windows we have are
  * Split pane
  * Floating window covering the full split pane (UI root)
    * TextInput float window in the correct position in the parent buffer
* Performance is important. Let's add benchmarks

#### Decisions (2026-07-02)
- **Root is ALWAYS a full-covering float** over the host window (even on split
  mounts). Rendering into the host window's buffer directly would let a resize
  clobber widgets before we can relayout (flicker), and subwindows need resize
  sync anyway.
- **Build alongside nui_host, migrate at the end** — nui_host, the current
  examples and the fibrous-docs site stay green until the new host reaches
  parity; then port + delete nui_host and vendored nui.
- **measure() takes a width constraint** — paragraphs wrap CSS-style (height
  depends on laid-out width). `raw_buffer` is the escape hatch when native
  Neovim wrapping is wanted (e.g. a massive streaming transcript where custom
  wrapping would be slow).
- **Two core targeted use-cases** drive the root constraint modes:
  1. width fixed to viewport, height unbounded → content taller than the
     viewport scrolls vertically natively (website-like);
  2. width AND height fixed (classic Neovim UI) → vertical grow/justify apply,
     content is bounded.
  Engine API: `layout.compute(tree, { width = w, height = h|nil })` — nil
  height = scroll mode (root height = content height, vertical grow/justify
  inert), fixed height = app mode.
- **Subwindow strategy: clipping first.** Partial occlusion = resize the float
  to its visible rows + re-anchor its viewport; fully occluded = hide. Known
  accepted artifact to evaluate: WinScrolled fires post-redraw, so floats lag
  the parent scroll by one frame ("swim"). If that proves annoying for text
  inputs, the *maybe-later* optimization is float-on-focus (inline placeholder
  when unfocused, float materializes on focus) — rejected as the default
  because an inline placeholder can't reproduce native wrapping of multiline
  float content. The clipping engine is needed for `raw_buffer` regardless.
- **Perf posture:** full measure + repaint per commit is acceptable to start;
  cache display-width lookups (`nvim_strwidth` per cell adds up); keep
  damage-tracking (repaint only dirty subtrees) in the back pocket, don't
  build it up front. Benchmarks (task 7) gate this.

#### Module plan — `lua/fibrous/inline/`
- `box.lua` — box-model resolution: per-side margin/padding/border normalization, border char sets
- `layout.lua` — pure two-pass engine: bottom-up `measure(node, max_w)`, top-down `layout(node, rect)`; row/col with grow/align/justify/gap
- `canvas.lua` — cell-grid painter → buffer lines + highlight spans (multibyte-safe)
- `render.lua` — laid-out tree → canvas: borders, padding, per-component painters
- `host.lua` — HostConfig: fiber tree → layout tree → commit into the root float buffer (extmarks, hit-map)
- `components.lua` — primitives: `rows, cols, label, paragraph, button, checkbox, text_input, raw_buffer`
- `interact.lua` — cursor-driven hover highlights + `<CR>`/`<Space>` activation via hit-map
- `subwin.lua` — subwindow floats: layout-driven position, scroll sync, partial/full occlusion, focus handoff
- `mount.lua` — floating + split mount targets (both create the root float; resize sync; teardown)

#### Task breakdown
- [x] 1. Layout engine core (pure Lua, TDD): box model, measure/layout passes, row/col grow/align/justify/gap, text wrap under width constraint
  - `lua/fibrous/inline/box.lua` + `layout.lua`; specs `tests/inline/box_spec.lua` (13) + `layout_spec.lua` (19). Grow = flex-basis-0 shares (remainder to last); explicit width/height are border-box and win over stretch; scroll mode makes vertical grow/justify naturally inert.
- [x] 2. Canvas renderer: cell grid → lines + highlight spans; per-side border drawing with custom chars; multibyte-safe
  - `lua/fibrous/inline/canvas.lua` (cell grid; byte-indexed merged hl spans for extmarks; wide-char cells with continuation handling) + `render.lua` (bg → border → content paint order; corners only where both adjacent sides exist; text cropped to its content box). Specs: `canvas_spec.lua` (8) + `render_spec.lua` (9).
- [x] 3. Inline HostConfig + root-float mount targets (floating + split), resize sync, teardown
  - `lua/fibrous/inline/host.lua` (HostConfig: whole fiber tree → layout.compute → render.paint → ONE host-owned unmodifiable scratch buffer, lines + extmarks in ns `fibrous_inline`; size read from injected `get_size` at every flush; `relayout()` re-flushes without re-rendering; `host.tree` keeps the laid-out tree with fiber backrefs for the task-6 hit-map) + `mount.lua` (`floating` = editor-relative root float, `split` = pane + covering relative="win" float; `mode = "fixed"|"scroll"`; coalesced WinResized/VimResized sync; WinClosed on pane or float tears the app down). Specs: `host_spec.lua` (8) + `mount_spec.lua` (7).
- [x] 4. Subwindow clipping risk-spike (pulled forward): one text_input float positioned by layout, scroll sync on WinScrolled, resize+re-anchor clipping, hide on full occlusion
  - `lua/fibrous/inline/subwin.lua`: text_input is laid out (and border/bg painted) INLINE; its content box is covered by an editable zindex-60 float keyed by fiber instance. Repositioning subtracts the root's topline (relative="win" floats anchor to the window grid, not scrolled content); partial top-clip resizes to visible rows + winrestview-scrolls the float's own topline; full occlusion → `hide = true`. WinScrolled (pattern = root winid) resyncs, synchronous/uncoalesced to minimize the swim. host.lua collects `host.subwins` per flush + `on_flush` hook; mount targets attach the manager and tear it down. Specs: `subwin_spec.lua` (6). Value seeding from props.value on create only (buffer = source of truth after); on_change/focus wiring is task 7.
  - [x] 4b. EVALUATE THE SWIM — verdict (2026-07-02, interactive eval): **no visible swim**; clipping strategy stays, float-on-focus stays a deferred task-10 option. Two feedback items from the eval: full-line hover on button/checkbox (fixed — see task 6 note) and no navigation into/out of subwindows yet (= task 7 scope, now unblocked).
- [x] 5. Component painters: label, paragraph, button, checkbox (unmodifiable inline content)
  - `lua/fibrous/inline/components.lua`: thin function components over the `text` host leaf (reconciler/host untouched). Prop mapping: `hl` = foreground (→ text_hl), `bg` = background fill (→ node hl); box/layout props pass through. button = `[ label ]`, checkbox = `[x]/[ ] label`; both forward handlers + a `role` marker onto node props (what the hit-map reads). Re-exports col/row/text/text_input. Specs: `components_spec.lua` (7).
- [x] 6. Cursor interaction: hit-map, hover highlight, `<CR>`/`<Space>` activation on the component under cursor
  - `lua/fibrous/inline/interact.lua`: hit-map = pure walk of `host.tree` for the deepest node with a `role` under the cursor (reverse child order = paint order; role-less subtrees fall through to the closest interactive ancestor — containers can be interactive). Hover paints the node's rect with `hover_hl` (default CursorLine) in its own namespace at priority 4200, re-evaluated on CursorMoved AND after every flush. `<CR>`/`<Space>` buffer-local: button → on_press(), checkbox → on_toggle(not checked). Wired into both mount targets alongside the subwin manager. Specs: `interact_spec.lua` (5). The `inline_scroll` example now demos hover/activation too. **Post-eval fix (2026-07-02):** button/checkbox used to stretch to the container width (default cross-axis align), so hover lit the whole line; added per-child `align_self` to the layout engine (overrides container `align`) and both widgets now default to `align_self = "start"` — hover hugs the widget; pass `align_self = "stretch"` or a `width` for full-width widgets.
- [x] 7. Subwindow engine (full): raw_buffer, focus traversal (edge motions hjkl/`<C-u>`/`<C-d>`, `<C-w>`-hjkl, parent-cursor entry into subwindow regions)
  - Focus traversal (`subwin.lua`): IN — CursorMoved on the root buffer (only when the root float is current); cursor cell inside a subwin's content box focuses its float at the corresponding cell. OUT — buffer-local n-mode maps per float buffer: `h/j/k/l` at the buffer edge exit into the root adjacent to the widget's border box, keeping the cursor's row/col alignment (non-edge → native motion, count preserved via `v:count1`); `<C-w>h/j/k/l` exit unconditionally; `<C-d>/<C-u>` always hand focus AND the motion to the root (page motions never trapped). Exits whose target is outside the root buffer are no-ops — staying put beats the root clamping the cursor straight back into the widget (re-entry loop). Specs: `focus_spec.lua` (5).
  - text_input wiring (`subwin.lua`): `props.on_change(value)` via **nvim_buf_attach on_lines** — NOT TextChanged/TextChangedI (main-loop events; never fire inside a feedkeys batch). on_lines runs under textlock, so the handler is `vim.schedule`d + coalesced per edit burst. `<CR>` (n+i, buffer-local): `props.on_submit(value)` when given; otherwise insert-mode `<CR>` feeds a literal newline (flags "in": before remaining typeahead, noremap). Handlers read off `entry.node.props` at fire time (latest committed). Guard: `reposition()` skips its winrestview while the float is the current window — otherwise the on_change → re-render → resync path yanks the cursor to col 0 mid-typing (covered by the clobber spec). Specs: `input_spec.lua` (4).
  - raw_buffer (`components.lua` + `host.lua` + `subwin.lua`): `ui.raw_buffer` subwindow leaf showing a caller-provided `props.bufnr` — UNOWNED: unmount removes our keymaps/autocmds but leaves the buffer alive (no bufnr → owned scratch, destroyed as usual). Default height = the buffer's line count (measured as N-1 newlines); explicit `props.height` wins. `props.wrap ~= false` → native wrapping escape hatch (text_input stays nowrap). Traversal callbacks fall back to native motions when the buffer is shown in a non-float window. Specs: `raw_buffer_spec.lua` (4).
  - `width.lua` gained shared `cell_to_byte` (moved from interact.lua; the traversal needs it for cursor placement). Suite after: 138 passed + the 2 pre-existing relayout failures.
- [x] 8. Benchmarks (`make bench`): full commit for N components, incremental update, scroll-sync tick
  - `bench/run.lua` (headless, isolated; `make bench` / `make bench BENCH_N=500`). Scenarios: pure layout+paint, mount, full re-commit (set_props), incremental update (one leaf use_state), scroll tick (WinScrolled subwin resync). Numbers at N=100 sections (~600 nodes, this machine, headless): pure layout+paint 2.5ms · mount 7.7ms · full re-commit 7.7ms · incremental 7.6ms · scroll tick 0.007ms. Perf work the bench forced (suite-guarded refactors): `width.lua` (memoized char widths + ASCII fast path — nvim_strwidth API overhead dominated), canvas rewritten to parallel per-row arrays (was a table per cell; alloc dominated), border edges via direct put. Before: full commit ~36ms. Damage tracking stays in the back pocket — remaining commit cost is reconciler + set_lines + ~2k extmarks, fine at realistic tree sizes.
- [x] 9. Migration: port examples + welcome panel + fibrous-docs site; delete nui_host + vendored nui (2026-07-03)
  - Public API (`lua/fibrous/init.lua`): `M.mount` = inline `mount.floating`, `M.mount_split` = `mount.split`, `M.mount_window` = `mount.window`, `M.ui` = the inline component set. `mount_as_window_host`, `M.components` and `M.hooks.use_keymap` are gone. Pinned by `tests/inline/api_spec.lua` (2).
  - Examples ported to the inline host: `hello` (bordered col of labels), `counter` (buttons via hit-map + the external-keymap actions pattern), `form` (text_input on_change/on_submit, cursor lands in the input via focus-follows-cursor), `sidebar` (cursor-driven list: plain labels given `role`/`on_press`/`hover_hl` — the hit-map needs only a role), `panel` (ACP shell: flex layout, `use_plan` custom hook, plan = checkboxes replacing the old scoped keymaps, prompt on_submit clears its own buffer — it IS current when the handler fires). All 7 examples smoke-tested headlessly (mount → non-blank render → unmount).
  - Deleted: `lua/nui/**` (vendored), `lua/fibrous/dom/` (nui_host), `lua/fibrous/mount/` (floating + window_host), `lua/fibrous/components/`, `lua/fibrous/hooks/` (use_keymap — its "bind across subtree leaf buffers" concept has no counterpart in the one-buffer inline host; cursor + hit-map replace it), `tests/{dom,mount,hooks}/` (incl. the 2 pre-existing failures). `fiber.scoped_keymaps` field removed; stale nui references in comments/README/examples cleaned.
  - fibrous-docs (`../fibrous-docs`) already runs on `fibrous.inline.mount`/`mount.window` — nothing to port there (its flake comment still says "with its vendored nui"; harmless, worth touching up on the next site change).
  - Suite after: **116 passed, 0 failed** (full run == per-file sum; first fully green suite).
- [ ] 10. Follow-up: mouse integration; float-on-focus text inputs if scroll-swim warrants it
