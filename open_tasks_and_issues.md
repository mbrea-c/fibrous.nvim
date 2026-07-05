# Open Tasks & Issues

## Project

- [x] Name the project `fibrous.nvim` (repo) / `fibrous` (Lua module)
  - Renamed `lua/nui-reactive/` → `lua/fibrous/`, all `require("nui-reactive…")`
    → `require("fibrous…")`, augroups `NuiReactive*` → `Fibrous*`,
    `vim.g.nui_reactive_example` → `vim.g.fibrous_example`, README/flake/design
    docs, and `nvim-react` → `fibrous` in `website_design.md`. Suite green (41
    passed).
  - [ ] Rename the on-disk repo directory `nui-reactive/` → `fibrous.nvim/`
    (left to you — renaming the live working dir mid-session would break the
    cwd)

## Bugs

- [x] Relayout (e.g. resize) clears visual selection
  - Fixed: neutralized nui's cursor-wiggle relayout workaround (no window switch
    / cursor move on relayout). Was pinned by
    `tests/mount/relayout_preserves_mode_spec.lua` (deleted with the nui host,
    2026-07-03).
- Split pane synchronization issues
  - [x] When mounted on a pane, closing the floats with `:q` leaves the pane
    open — resolved by the inline mount (`wire()`'s WinClosed on the root float
    closes the pane in `on_teardown`); pinned 2026-07-03 by the mount_spec test
    ":q on the root float tears down the app AND its pane".
- [x] Pre-existing suite failures (2, nui-host relayout specs; confirmed on a
  clean tree 2026-07-02, unrelated to the inline host work):
  `relayout_no_sync_redraw_spec` (expected 0 redraws, got 4) and
  `relayout_preserves_mode_spec` (visual mode dropped to normal) — likely an
  nvim-version behavior change; both guarded the old nui host and were deleted
  with it (task 9 migration, 2026-07-03). Suite fully green since.

## Website / WASM playground (`website_design.md`)

A fullscreen, client-side Neovim (WASM) homepage whose UI is built natively in
fibrous. Three decoupled tiers: this library (Lua) → WASM Neovim engine → docs
SPA.

### Tier 2 — Neovim-in-WASM engine (`../nvim-wasm-core`, separate repo)

**Decision (2026-06-30):** build our **own** MIT-licensed Neovim→WASM wrapper.
Rationale: we need a Nix-flake build regardless, and no viable existing artifact
exists with a license that permits redistribution.

Target architecture (supersedes the Emscripten sketch in `design.md §2.2/§4.1` —
chosen because it needs **no SharedArrayBuffer / no COOP-COEP headers** → plain
static edge hosting):

- Compile upstream Neovim as **wasm32-wasi** via **wasi-sdk** (clang), not
  Emscripten.
- Run the Binaryen **Asyncify** pass (`wasm-opt --asyncify`) so the synchronous
  WASI event loop can yield to the browser without threads.
- Browser side: **`@bjorn3/browser_wasi_shim`** provides the WASI imports; the
  Neovim `$VIMRUNTIME` ships as an **`fflate`**-compressed tarball unpacked into
  the in-memory WASI FS.
- Drive the UI over Neovim's **msgpack-RPC** (`--embed`) → frontend grid.

Incremental build plan (each step has a runnable smoke check under headless
`wasmtime` in CI before moving on):

- [x] Scaffold `../nvim-wasm-core` (own repo, MIT) with its own `flake.nix`:
  devShell + checks using nixpkgs `pkgsCross.wasi32` clang toolchain +
  `binaryen` + `wasmtime` + `cmake`/`ninja`/`pkg-config`. (No bundled `wasi-sdk`
  in nixpkgs; `pkgsCross.wasi32` gives a `wasm32-unknown-wasi` clang wrapper,
  which is cleaner. `uvwasi` available for the libuv→WASI layer.)
- [x] Spike 0 — compile `spike/hello.c` → `hello.wasm` via the cross stdenv;
  `checks.hello-runs` runs it under `wasmtime` in the build sandbox and asserts
  output. `nix flake check` GREEN.
- [x] Map Neovim's build deps for wasm32-wasi. **Empirical result (2026-06-30)**
  using `nixpkgs#pkgsCross.wasi32.*` (needs
  `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 --impure`):
  - ✅ **Build clean:** `utf8proc`, `msgpack-c` (pure C, no terminal/syscall
    deps).
  - ❌ **`libuv`** — source won't compile (`unix/core.c`, `fs.c`, `inet.c`):
    nixpkgs has **no WASI port** of libuv. This is THE linchpin — Neovim's whole
    event loop is libuv. Needs a WASI-patched libuv. `uvwasi` in nixpkgs is the
    *inverse* (WASI-on-libuv for runtimes), not what we need.
  - ❌ **terminal stack** (`libvterm`, `unibilium`, `libtermkey`) +
    **`readline`→`ncurses`** — ncurses fails configure's link conftest under
    wasi (suspect the `-Wl,--undefined-version` LDFLAG, which `wasm-ld`
    rejects). This chain is the TUI we *don't* want for an `--embed`/RPC build,
    so the move is to drop/stub it, not fix it.
  - ❌ **`tree-sitter`** (Rust) — cc-wrapper passes
    `--target wasm32-wasip1 != wasm32-unknown-wasi`; multi-target wrapper
    mismatch. Needs an unwrapped compiler or triple alignment.
  - Conclusion: `nix build pkgsCross.wasi32.neovim` is **not** viable as-is;
    nixpkgs wasi32 is useful only as a *parts bin* for the easy leaf libs.
    Strategy = hand-rolled derivation (nixpkgs leaf libs where they work + our
    patched libuv + PUC Lua + TUI stripped).
- [x] **Linchpin: WASI libuv — DONE (2026-06-30).**
  `../nvim-wasm-core/pkgs/libuv-wasi` builds a real `libuv.a` for wasm32-wasi,
  wired into the flake as `packages.libuv-wasi` + green check
  `checks.libuv-loop-runs` (a `uv_timer` program ticks 3× under wasmtime and the
  loop exits). **Architecture pivot away from the patch-real-libuv plan below:**
  real-libuv-on-WASI is a dead end — wasi-libc gates the *entire*
  sigset/sigaction masking API
  (sigemptyset/sigaddset/sigprocmask/sigaction/`struct sigaction`/`sigset_t`)
  behind the never-defined `__wasilibc_unmodified_upstream`, and
  `_WASI_EMULATED_SIGNAL` does **not** expose it (only ungates the header +
  `signal()`/`raise()`). `posix-poll.c`/`signal.c` therefore can't compile. So
  we **replace the library**: keep libuv's public headers, compile a single
  self-written `pkgs/libuv-wasi/stub.c` that reimplements the public API
  (userspace loop: timers/idle/prepare/check/async/close + real WASI fs ops;
  ENOSYS for net/process/tty/signal/thread). `default.nix` patches
  `include/uv/unix.h` (drop absent `netdb.h`/`termios.h`/`pwd.h` on `__wasi__`,
  add a `#include "uv/posix.h"` platform branch, strip `struct termios` from
  `UV_TTY_PRIVATE_FIELDS`), compiles stub.c with `-D_WASI_EMULATED_SIGNAL`,
  `ar`s `libuv.a`. **Consumers of these headers must compile
  `-D_WASI_EMULATED_SIGNAL` and link `-lwasi-emulated-signal`** (uv.h → signal.h
  is an `#error` otherwise); Neovim will do the same. stub.c is reference-clean
  (own implementation; no upstream backend source). Remaining `uv_*` symbols
  (tcp/pipe/tty/process/signal/thread/dns) get added to stub.c on demand when
  the Neovim link surfaces exactly which are referenced.
  - ~~Confirmed there is **no upstream libuv WASI platform** and **no
    license-clean drop-in** — porting is unavoidable engineering (add a libuv
    `wasi` platform / stub the unix syscall files). Everything else is
    downstream of this.~~ (Superseded by the stub.c approach above — the "patch
    the real unix backend" framing was wrong; the signal wall makes it
    unworkable.)
  - **DECISION (2026-06-30): toolchain = (A) nixpkgs `pkgsCross.wasi32`.**
    Spiked both: nixpkgs libuv *configures cleanly* for
    `--host=wasm32-unknown-wasi` and compiles until it hits missing headers —
    first `netdb.h`, then `termios.h`. Stubbing `netdb.h` advanced the build
    (confirms the gaps are headers, not the toolchain). Crucially, the missing
    headers (`netdb.h`, `termios.h`, `pwd.h`, `net/if.h`) are absent from
    wasi-libc **by WASI design** (no DNS / terminals / user-db / netif), so
    **wasi-sdk 29 lacks them too** → the toolchains are equivalent for the libuv
    port. Chose A for hermetic reproducibility (clang 21 / wasilibc 27, already
    in our flake, Spike 0 green). Add `-fwasm-exceptions` where C++ EH is needed
    (clang 21 supports it). Spike artifacts: `scratchpad/libuv-spike.nix`.
- [x] **libuv wasi implementation — DONE via stub.c (see linchpin item above).**
  Superseded the "build libuv's real unix backend + shim headers" plan: instead
  of compiling `core.c`/`fs.c`/`posix-poll.c`/etc., `pkgs/libuv-wasi/stub.c`
  reimplements the public API directly (loop+timers+idle+async+fs real;
  net/tty/process/signal/thread = ENOSYS). No shim headers needed — the unix.h
  patch drops the 3 absent headers, and every other POSIX header libuv wants
  (`sys/socket.h`, `netinet/*`, `arpa/inet.h`, `sys/param.h`, `pthread.h`,
  `semaphore.h`, `signal.h`) is present in wasi-libc 27. The 4 shim-header files
  (`netdb.h`/`termios.h`/`pwd.h`/`net/if.h`) and the `wasi_socket_ext.h`
  force-include were deleted.
  - ~~**Port surface mapped (2026-06-30 spike, `make -k`):** with the 4 shim
    headers in place, all remaining compile errors live in the networking + tty
    backends only…~~ (Obsolete: that spike was against the abandoned
    real-backend approach. The signal-masking wall — not sockets/tty — is what
    actually killed it; stub.c sidesteps the whole thing.)
- [~] Cross-compile remaining Neovim deps for wasm32-wasi. **PUC Lua 5.1 — DONE
  (2026-07-01):** `../nvim-wasm-core/pkgs/lua51-wasi` builds `liblua.a` (strict
  `-DLUA_ANSI`, no readline; nixpkgs' lua5_1 can't cross — pulls readline which
  wasm-ld rejects). Wired as `packages.lua51-wasi` + green check
  `checks.lua-embed-runs` (embed Lua, run `for`-loop + `string.format` script →
  `sum=55 lua=Lua 5.1` under wasmtime). Two WASI-isms solved and **reusable for
  every C dep below (luv, tree-sitter, nvim itself):**
  1. **setjmp/longjmp → wasm EH.** wasi-libc's `<setjmp.h>` is an `#error`
     unless you compile with `-mllvm -wasm-enable-sjlj` and link `-lsetjmp`.
     That lowering emits *legacy* EH `try`, which wasmtime 45 rejects;
     post-process the **final linked module** with `wasm-opt --emit-exnref -all`
     (binaryen, already in flake) and run `wasmtime -W exceptions=y`. Any dep
     using setjmp (Lua's error handling does) inherits this whole pipeline.
  1. **Missing libc fns.** wasi-libc *declares* but doesn't *implement*
     `system`/`tmpnam`/`tmpfile`/`clock` (no process spawn / temp files /
     process clock; `-lwasi-emulated-process-clocks` only ships `times`, not
     `clock`). `pkgs/lua51-wasi/wasi_compat.c` bakes failing stubs into the
     archive (clock → real monotonic impl). Also `-DL_tmpnam=260` (macro
     absent). Consumers just link `-llua -lsetjmp -lm`.
  - **AUTHORITATIVE DEP MAP (2026-07-01, top-down probe of nixpkgs neovim 0.12.3
    = our target).** Extracted from `src/nvim/CMakeLists.txt` `find_package`
    calls + `cmake.deps/deps.txt`. Our libuv-wasi (1.52.1) and lua51-wasi
    (5.1.5) **exactly match Neovim 0.12.3's pins** (it wants libuv ≥1.28, Lua
    5.1 EXACT). Nvim also pins luv `1.52.1-0`, lpeg `1.1.0`, lua-compat-5.3
    `v0.13`, utf8proc `v2.11.3`, tree-sitter `v0.26.7`.
    - **External REQUIRED link deps.** ✅ **`luv` — DONE (2026-07-01):**
      `pkgs/luv-wasi` builds `libluv.a` from nixpkgs' luv `1.52.1-0` (exactly
      nvim's pin; single-TU amalgamation + bundled lua-compat-5.3). Wired as
      `packages.luv-wasi` + green **integration check `checks.luv-runs`**: a Lua
      script drives `uv.new_timer` end-to-end (lua51-wasi + luv + libuv-wasi) →
      ticks 3× under wasmtime. This forced **completing libuv-wasi's public
      symbol surface**: luv references 258 `uv_*`; stub.c had 68; the other
      **190 are now `pkgs/libuv-wasi/stub_ext.c`** (generated by `gen_stubs.py`
      from uv.h — type-correct, mostly `UV_ENOSYS` for
      sockets/subprocess/TTY/thread/DNS, with single-threaded no-op-success sync
      primitives: mutex/once/key/sem). luv needed two small WASI shims:
      `pkgs/luv-wasi/shims/netdb.h` (absent header — struct addrinfo/protoent +
      AI\_/NI\_ constants) force-included via `shims/wasi_compat.h`, and
      `wasi_stub.c` (getprotoby\*/get·setuid/gid stubs). Consumers link
      `-lluv -llua -luv -lsetjmp -lwasi-emulated-signal -lwasi-emulated-getpid -lm`.
      ✅ **`utf8proc` + `lpeg` — DONE (2026-07-01):** `pkgs/utf8proc-wasi`
      (v2.11.3, nvim's exact pin — self-contained 2-file C, `-DUTF8PROC_STATIC`)
      and `pkgs/lpeg-wasi` (v1.1.0, exact pin — 6 plain-C TUs incl. `lpcset.c`,
      links lua51-wasi headers only). **Both needed ZERO WASI shims** — pure C,
      no OS deps, as predicted. Green checks `checks.utf8proc-runs` (case-fold +
      NFC under wasmtime, no Lua) and `checks.lpeg-runs` (digit grammar inside
      Lua). ✅ **`tree-sitter` — DONE (2026-07-01):** `pkgs/tree-sitter-wasi`
      builds the runtime from nixpkgs' v0.26.8 (nvim pins 0.26.7; ≥0.25 required
      — satisfied) as a single amalgamation `lib/src/lib.c`,
      `-I lib/include -I lib/src`, **no `TREE_SITTER_FEATURE_WASM`** (that
      feature embeds wasmtime to run grammars-as-wasm — can't nest;
      `wasm_store.c` compiles to nothing without it). **Zero WASI shims** —
      plain C99. Green check `checks.tree-sitter-runs` (parser lifecycle +
      ABI=15 under wasmtime). Grammars (tree-sitter-c/lua/vim/…) are separate
      generated parsers compiled into nvim later, not a runtime dep. ✅ **`iconv`
      — DONE (2026-07-01), needs NOTHING from us:** wasi-libc 27 already ships a
      real iconv (`iconv.h` in the sysroot + `iconv`/`iconv_open`/`iconv_close`
      in `libc.a`, musl-derived ~500-byte impl). Verified under wasmtime:
      ISO-8859-1 `é`(0xE9) → UTF-8 (0xC3 0xA9), rc=0. Neovim's `FindIconv` only
      *requires* the header (`ICONV_LIBRARY` is optional) → it'll resolve from
      the sysroot with no flags. **The reference shimmed iconv only because
      their wasi-sdk 29 lacked it; our wasi-libc 27 has it.** lua-compat-5.3 is
      already vendored inside luv (and nvim bundles its own copy too).
  - 🎯 **ALL external REQUIRED Neovim deps are now satisfied** (libuv ✅ Lua ✅ luv
    ✅ lpeg ✅ utf8proc ✅ tree-sitter ✅ iconv ✅-in-libc). 6 green wasmtime checks.
    **The dependency wall — the item this doc called "the linchpin" — is
    cleared.** Next: write the CMake wasi32 cross-toolchain file and attempt the
    actual `nvim.wasm` configure/build against these artifacts (with
    `-DPREFER_LUA=ON -DENABLE_WASMTIME=OFF -DENABLE_UNIBILIUM=OFF -DENABLE_LIBINTL=OFF`),
    then work the nvim-level shims (signal/pty/stdio-RPC) + Asyncify per the
    reference's `wasi-shim/` + `asyncify/`.
    - **Optional deps to DISABLE (drops them entirely):**
      `-DENABLE_WASMTIME=OFF` (nvim 0.12 can embed wasmtime 36 to run
      tree-sitter grammars-as-wasm — we obviously can't nest a Rust wasm
      runtime; disable), `-DENABLE_UNIBILIUM=OFF` (terminfo/TUI),
      `-DENABLE_LIBINTL=OFF` (i18n/gettext). Set `-DPREFER_LUA=ON` to select PUC
      Lua 5.1 over LuaJIT.
    - **NOT external deps — vendored in the nvim source tree, compile as part of
      nvim.wasm:** `msgpack` (→ `src/mpack/`, nvim's own mpack), `libvterm` (→
      `src/nvim/vterm/`), `libtermkey` (→ `src/nvim/tui/termkey/`). **This kills
      the old "TUI terminal stack" worry** — vterm/termkey/mpack need no
      separate derivation; they build with nvim (the open question is only
      whether they *run* headless, not whether they link).
    - Deferred: the actual CMake cross-toolchain file (wasi32 clang) — write it
      once the REQUIRED external deps above exist; a full cross-configure now
      would just fail on missing deps.
- [x] **Build `nvim.wasm` — DONE (2026-07-01).** Upstream Neovim 0.12.3
  (`neovim-unwrapped.src`, PUC Lua 5.1) cross-compiles and **runs under
  wasmtime**: `--version` banner ✅, headless `+q` clean exit ✅, `:lua` eval
  (`vim.fn`/`vim.api`) ✅, full buffer edit + `:wq` round-trip through the WASI
  fs ✅. Packaged as `packages.nvim-wasi` (`pkgs/nvim-wasi/`) + check
  `checks.nvim-runs`; output = `nvim.wasm` (~12.8MB, RelWithDebInfo) +
  `runtime/` tree. Run:
  `wasmtime run -W exceptions=y --dir runtime::/runtime --env VIMRUNTIME=/runtime nvim.wasm`.
  Key findings:
  - **No build-system patching needed for codegen:** Neovim's own cross hook
    (`NLUA0_HOST_PRG` + `LUA_GEN_PRG`, src/nvim/CMakeLists.txt) runs all code
    generation with a host lua + host-built `nlua0.so` →
    `pkgs/nvim-wasi/nlua0.nix` (native derivation), consumed by the cross
    configure. Two-stage build proven end-to-end.
  - **Toolchain:** `pkgs/nvim-wasi/toolchain-wasi.cmake`
    (`CMAKE_SYSTEM_NAME=WASI`, env-driven
    `WASI_SHIM_DIR`/`WASI_COMPAT_H`/`WASI_SHIM_OBJ`). Gotcha ×2:
    `CMAKE_FIND_ROOT_PATH` only re-roots — prefixes must ALSO be in
    `CMAKE_PREFIX_PATH` (hit for wasi libs and sysroot iconv).
  - **nvim-level WASI shims (`pkgs/nvim-wasi/`):** `shims/netdb.h` +
    `shims/termios.h` (headers absent from wasi-libc, `-idirafter`);
    `shims/wasi_nvim_compat.h` force-included everywhere (struct winsize,
    SIG_SETMASK consts, dup/dup2/umask/pthread_exit decls, F_DUPFD_CLOEXEC);
    `shim.c` (no-op bodies: termios/sigmask/tcdrain; dup/dup2→ENOSYS, umask→022,
    pthread_exit→\_exit); `pty_proc_unix.c` whole-TU replacement
    (forkpty/grantpt unshimmable → `:terminal` spawn = ENOSYS; same path so
    `*.c.generated.h` codegen applies — done via `postPatch` cp).
  - **libuv stub grew real env/cwd support:**
    `uv_os_getenv/setenv/unsetenv/environ/homedir/tmpdir/get_passwd`,
    `uv_cwd`/`uv_chdir` now real (wasi-libc backs getenv/environ; getcwd/chdir
    emulated userspace) + `uv_dl*` (dlopen→error) and `uv_mutex_init_recursive`.
    NOTE: `stub_ext.c` is now hand-curated — merge, don't overwrite, when
    regenerating with gen_stubs.py.
  - Same sjlj pipeline as every Lua artifact: `-mllvm -wasm-enable-sjlj` →
    `wasm-opt --emit-exnref -all` → `wasmtime -W exceptions=y`.
- [x] **First browser boot — DONE (2026-07-01).** `nix run .#nvimwasm` serves
  `packages.nvim-wasm-web` (web/ page + @bjorn3/browser_wasi_shim 0.4.2 +
  $VIMRUNTIME as tar.gz unpacked via DecompressionStream into the shim's
  in-memory FS) and opens Firefox in kiosk (fullscreen) mode; nvim.wasm runs
  `--version` + a headless Lua API demo (vim.version, buffer round-trip, file
  write/read through the WASI fs) streaming to the page. Batch-style only —
  interactive editing still needs Asyncify. Browser-vs-wasmtime landmines found:
  (1) wasi-libc `access()` checks WASI rights bits which browser_wasi_shim
  zeroes → all files "unreadable" → libuv stub's `uv_fs_access` now
  stat()-based; (2) the shim's per-syscall debug logging is ON by default (+
  nvim writes stderr byte-at-a-time) → must pass `{debug:false}`; (3) a modified
  listed buffer makes `:q` wait for input forever (no interactive stdin) → demos
  must use scratch buffers + `:qa!`.
- [x] **Interactive Neovim UI in the browser — DONE (2026-07-02).**
  Architecture: **`nvim --embed` (msgpack-RPC server on stdin/stdout) + a JS UI
  client** (canvas ext_linegrid renderer), i.e. the same client/server split
  every GUI (Neovide etc.) uses. Verified end-to-end three ways: wasmtime pipe
  test (attach → full first frame → `:qa!` exit 0), node replica of the browser
  boot path (sync scripted poll driver, PASS), and node with real JSPI
  (`--experimental-wasm-jspi`: typed text into a buffer via `nvim_input`, quit
  cleanly, PASS). Key decisions/findings:
  - **Asyncify is dead, JSPI replaces it:** binaryen's Asyncify pass crashes on
    wasm-EH modules (`UNREACHABLE at Flatten.cpp:231`) and our sjlj pipeline
    requires EH. Instead the one blocking import, `poll_oneoff`, is wrapped in
    **`WebAssembly.Suspending`** and `_start` driven via
    **`WebAssembly.promising`** (JSPI — shipped by default in Firefox 152+ and
    Chrome 137+; **Firefox 151 and earlier need `about:config` →
    `javascript.options.wasm_js_promise_integration = true`**, verified working
    on 151.0b9; no COOP/COEP, static hosting preserved). Non-JSPI browsers fall
    back to the old batch demo — note the batch headless step is known to
    hang/spin on Firefox (shim's busy-wait poll_oneoff), so on Firefox the pref
    is effectively required.
  - **In-process TUI is impossible by design:** nvim 0.10+ spawns *itself* as a
    child `--embed` server for the builtin TUI (`main.c`
    `ui_client_start_server`) — no process spawn under WASI. `--embed` +
    external UI is the only interactive shape, and the protocol-native one
    anyway.
  - **libuv-wasi stub grew a real stream layer** (`pkgs/libuv-wasi/stub.c`):
    fd-backed pipe/tty streams
    (`uv_pipe_*`/`uv_tty_*`/`uv_read_start`/`uv_write`…), reads driven by
    `poll(2)` inside `uv_run` (wasi-libc lowers poll → poll_oneoff →
    JSPI-suspendable), writes synchronous with libuv-contract deferred
    callbacks; blocking-poll-then-break semantics so UV_RUN_ONCE drains nvim's
    multiqueue (deadlock otherwise). 18 stream symbols deleted from `stub_ext.c`
    (still hand-curated — merge, never regenerate over it).
  - **channel.c patch** (nvim-wasi postPatch): embedded stdio channel re-homes
    fds via `fcntl(F_DUPFD_CLOEXEC)`+`dup2` (both absent on WASI) → keep the RPC
    channel on fds 0/1.
  - **Web client** (`web/`): self-written `msgpack.js` (streaming codec),
    `nvim_io.js` (stdin/stdout character-device Fds + real poll_oneoff — the
    shim's builtin only handles a single clock sub and busy-waits, and never
    writes `nevents`), `renderer.js` (canvas ext_linegrid grid: hl attrs,
    scroll, cursor shapes via mode_info), `keys.js` (KeyboardEvent →
    `nvim_input` key-notation). `nix run .#nvimwasm` now boots straight into an
    editable Neovim.
  - Landmine (bit us TWICE): pages cached before the server sent
    `Cache-Control: no-store` are heuristically fresh for years (nix mtime 1970)
    and Firefox kept executing a months-old main.js (visible as
    `runNvim@main.js` frames + `wasi:` debug spam — functions that no longer
    exist). Fixed for good: server sends no-store AND the default port moved
    8397 → 8402 (new origin = clean cache); main.js banner now prints a build
    tag so staleness is obvious.
- [x] **Nix consumer API + graceful degradation — DONE (2026-07-02).**
  - **`lib.<system>.mkNvimWasmWeb { initLua, plugins, font = {family,px}, env, extraXdg }`**
    (pkgs/nvim-wasm-web, `lib.makeOverridable`;
    `packages.nvim-wasm-web = mkNvimWasmWeb { }`). Plugins/init.lua ship as
    `config.tar.gz` mounted at `/xdg` (`XDG_CONFIG_HOME=/xdg/config`,
    `XDG_DATA_HOME=/xdg/data`, plugins under `data/nvim/site/pack/web/start/*`);
    font+env flow via `config.json`. Writable state stays under `HOME=/work`.
    Verified end-to-end (node test asserts init.lua text, plugin text, and env
    marker all render in the grid; Chromium screenshot confirms font px). This
    IS the Tier-2→Tier-3 artifact interface. README documents it.
  - **No-JSPI browsers no longer lock up**: the page shows what's missing +
    exact instructions (Firefox 139–151 pref name, versions that work OOTB) and
    runs only a safe `nvim --version` proof-of-life (the old headless demo
    busy-spun the tab via the shim's poll_oneoff). Verified by Firefox
    screenshot without the pref.
  - **Bug found & fixed on the way: the entire uv_fs scandir family was ENOSYS**
    (stub_ext.c) — `vim.fn.readdir`, `globpath`, and **pack/\*/start plugin
    discovery silently found nothing**, under wasmtime too. Implemented
    `uv_fs_scandir/_next`, `uv_fs_opendir/readdir/closedir` for real in
    pkgs/libuv-wasi/stub.c (wasi-libc readdir(3); state freed via
    `uv_fs_req_cleanup`). `vim.fs.dir`/plugin loading now work everywhere.
- [x] Mouse support in the web client — DONE (2026-07-03). `web/mouse.js`:
  DOM-free adapter (handlers take plain `{x, y, ...}` px objects, emit
  `nvim_input_mouse` args) wired in `main.js` — buttons press/drag/release
  deduped per cell crossing, unpressed motion as "move" (inert unless the guest
  sets 'mousemoveevent'), wheel px deltas accumulated into one tick per cell
  height (trackpads fire many tiny deltas), S-/C-/A-/D- modifiers, contextmenu
  suppressed (right-click belongs to the guest). Touch included: tap (sub-8px
  slop) = left click, finger drag = wheel ticks at the current finger cell
  (finger up = wheel down), `touch-action: none`. Pinned by
  `checks.web-mouse-unit` (node --test, 8 cases, red-green). Guest-side behavior
  (click-to-activate etc.) is fibrous' NEW UI HOST task 10 — identical in
  terminal and web by construction.
- [x] `mkNvimWasmWeb`: `extraLuaFiles` / `extraLuaDirs` alongside `initLua` —
  DONE (2026-07-03). Both ship under `config/nvim/lua/` (the config dir is
  already on the rtp, so they're plain `require()` modules):
  `extraLuaFiles = { "site/util.lua" = ./f; }` (keys = paths under `lua/`,
  values file-or-Lua-string like initLua) → `require("site.util")`;
  `extraLuaDirs = [ ./lua ]` overlays whole trees. Pinned by new
  `checks.web-config-rtp` (red-green: untars config.tar.gz, asserts layout,
  boots nvim.wasm headless with the XDG tree and asserts a module from EACH
  surface require()s and round-trips through the WASI fs). README updated.
  Unblocks splitting fibrous-docs' site/init.lua into modules.
- [ ] Revisit `$VIMRUNTIME`/config tarball size & lazy-loading (works today via
  DecompressionStream; ~unoptimized).

### Tier 3 — `fibrous-docs` (static site, `../fibrous-docs`)

- [x] **Site scaffold — DONE (2026-07-02).** The old Emscripten-era plan
  (lua_bundle.js / VFS JSON / xterm.js) is obsolete — Tier 2's `mkNvimWasmWeb`
  already does all of it. `../fibrous-docs` is now: `flake.nix` (packages.site =
  `mkNvimWasmWeb { plugins = [ fibrous ]; initLua = ./site/init.lua; font.px = 17; }`
  — the fibrous repo with vendored nui ships as a pack/start plugin),
  `site/init.lua` (VimEnter: dofile the repo's examples/init.lua for
  :Example/:Examples, then mount a fibrous-rendered welcome panel; note pack
  plugins are NOT on rtp during init.lua — defer everything), `nix run` local
  server (port 8410), README, MIT LICENSE.
  - **Verified end-to-end in node**: welcome panel renders → `q` +
    `:Example counter` → `+++` → `Count: 3` → `-` → `Count: 2` → `:qa!` exit 0.
    use_state/use_effect/keymaps/nui popups all work inside nvim.wasm. Chromium
    screenshot confirms the browser rendering. Testing lesson: **ext_linegrid
    sends delta cells** — asserting on a concatenated grid_line stream misses
    re-renders (only the changed digit is sent); tests must maintain a real 2D
    grid model.
- [x] **GitHub Pages — DONE (workflow) / BLOCKED (activation).**
  `.github/workflows/pages.yml`: nix build .#site → upload-pages-artifact →
  deploy-pages on push to main. Static hosting is sufficient (no COOP/COEP
  needed — JSPI, not SharedArrayBuffer). **Before CI can build**: publish
  nvim-wasm-core + fibrous.nvim to GitHub and switch fibrous-docs' flake inputs
  from `path:/home/manuel/src/...` (local-dev only; relative path inputs can't
  escape the flake root) to `github:` URLs — TODO markers in flake.nix; also set
  repo Settings → Pages → Source: GitHub Actions.

### UI demos (built in fibrous, run inside the WASM instance)

- [x] **Homepage with live playgrounds — DONE (2026-07-03)** (`../fibrous-docs`
  site/lua/webapp/\*, replaces the scroll-spike welcome panel; subsumes the
  "interactive counter" item below). Scroll-mode fullscreen page:
  figlet-colossal masthead ("fibrous" / ".nvim", ~20 rows), pitch paragraph,
  then 4 playground sections (webapp/examples.lua): Reactive state (counter),
  Cursor-native widgets (todo: checkboxes + text_input on_submit), A CSS-like
  box model (borders/padding/grow/hover), Effects & timers (uv timer clock with
  cleanup). Each section = intro paragraph → 80×40 lua-filetype raw_buffer
  editor beside the component its chunk returns → "Reload preview" button +
  `<C-CR>` → details paragraph (webapp/playground.lua). Reload compiles the
  buffer (loadstring): compile errors keep the last good preview and show
  `error: …`; render-time errors are caught by an ERROR BOUNDARY component
  (pcall wrapper, no own hooks so user hook slots stay positionally stable) — a
  playground mistake never takes the page down. Editor buffers persist per
  session in a module registry (`playground.editor_of(name)` accessor). Tests:
  fibrous-docs got its own harness-reusing `tests/run.lua` (sibling fibrous via
  FIBROUS_PATH, so specs run against the LOCAL tree, not the flake pin) +
  `home_spec.lua` (5: render, seeded editors, reload swaps preview,
  compile-error surfacing, boundary) — judgement call per user: playground
  mechanics are specced, visual details are not. `nix build .#site` green;
  webapp modules ship via extraLuaDirs.
  - Post-review round (2026-07-03): banner centered via `align_self = "center"`
    on its col (centering the labels individually would shear the art); editor
    heights now fit each example (`#code_lines + 2` for the border rows) instead
    of a fixed 40; **wasm gotcha**: the runtime lua ftplugin's first line is an
    unguarded `vim.treesitter.start()` and nvim.wasm has no loadable parsers
    (bundled ones are dlopen'd .so) → E5113 on `filetype=lua`. First fix attempt
    (pre-set `vim.b.did_ftplugin = 1`) DOESN'T work: ftplugin.vim's loader
    `unlet!`s the flag before sourcing (and `-u NONE` spec runs load no
    ftplugins, hiding the failure — verified with `--clean`). Real fix: set
    `vim.bo.syntax = "lua"` and no filetype at all (no FileType event → no
    ftplugin; regex syntax loads via the Syntax autocmd — and looks identical
    browser/terminal, where filetype would have used treesitter locally), plus a
    browser-wide pcall wrap of `vim.treesitter.start` in site/init.lua so a
    visitor's `:e foo.lua` survives too. Site theme: `webapp/theme.lua`, a
    hand-rolled midnight palette (tokyonight-adjacent; no colorscheme plugin so
    it works in wasm) applied via nvim_set_hl at webapp require time — chrome
    groups, editor lua syntax groups, and fibrous' hooks (LineNr borders,
    Directory focus accent, CursorLine hover); `laststatus=0` in site/init.lua.
    The site mounts with `mouse = { follow = true }` (focus-follows-mouse: web
    client streams pointer motion, fibrous moves the cursor to it — hover +
    traversal-into-inputs ride along); FFM stays opt-in for terminal fibrous
    users.
- [x] Interactive counter: source-code pane (left) + live rendering button
  (right) responding to keyboard/mouse — subsumed by the homepage playground
  (first section)
- [ ] DevTools reconciliation inspector: togglable overlay of the live VDOM tree
  with re-render flash highlights

### Mobile / UX & risk mitigations

- [x] Tap→click — DONE (2026-07-03) in Tier 2's `web/mouse.js` (see Tier 2
  section): tap = `nvim_input_mouse` left press+release at the touched cell.
- [x] Gestural scroll — DONE (2026-07-03), same place: `touchmove` deltas
  accumulate into wheel up/down ticks per cell height at the current finger
  cell; >8px movement disqualifies the tap.
- [x] Mobile follow-ups from the touch spike — DONE (2026-07-04), all in Tier
  2's `web/` (ships to the site via the fibrous-docs flake pin):
  - **Virtual keyboard**: `#kbd`, a visually-hidden textarea IME relay.
    Physical keys are handled document-level via keyToNvim (preventDefault
    also stops the textarea mutating — nothing delivers twice); soft keyboards
    bypass keydown (keyCode 229) and speak input/composition events, decoded
    against a one-char sentinel (so backspace always has something to delete)
    and forwarded as nvim_input text (`<` → `<lt>`, newlines → `<CR>`). On
    coarse-pointer devices focus (= keyboard visibility) follows the guest
    mode via a renderer.onMode hook. Viewport meta
    `interactive-widget=resizes-content` \+ `100dvh` sizing means the keyboard
    shrinks the viewport and the grid re-fits above it through the normal
    resize path.
  - **Android OSK fix** (2026-07-04, real-device bug report): the original
    mode-following was broken two ways. (1) Its summon regex included
    `replace`, but nvim's ui_flush fakes `mode_change("replace")` whenever the
    cursor sits behind a higher-zindex float (the same artifact cursorshim.lua
    counters in fibrous-docs) — scrolling the float-heavy fibrous UI emitted
    replace/normal bursts, and since Android only raises the OSK on focus
    within the transient-activation window after a touch, the keyboard
    appeared erratically mid-scroll and flickered. (2) Chicken-and-egg: taps
    leave the guest in normal mode and you can't press `i` without a keyboard,
    so the OSK never came up on purpose. Fix: focus policy extracted into
    DOM-free `web/keyboard.js` (node-tested, 9 specs, in
    checks.web-mouse-unit) — only `insert|cmdline|terminal` summon, only
    `normal|visual|operator` dismiss (debounced 200ms), everything else
    (crucially `replace`) is NEUTRAL; a visible ⌨ button (`#kbdbtn`,
    coarse-pointer only) summons inside a real tap gesture and PINS the
    keyboard through normal-mode navigation until tapped again; canvas taps
    re-summon when the guest is in an insert-ish mode (recovers from
    back-button dismissal). Still needs a real-device pass.
- [x] Click-to-insert — DONE (2026-07-04), fibrous-side completion of the OSK
  story: clicking a text field enters it in INSERT mode, GUI-style (a pointer
  user may have no keyboard; on mobile insert mode is also what summons the
  OSK via mode-following). `<CR>` deliberately keeps normal-mode entry —
  whoever pressed it has a keyboard and `i` is right there. Two halves in
  subwin.lua behind one `click_insert(entry)` policy (text_input default on,
  raw_buffer default off, `insert_on_click` prop overrides): the root
  `<LeftRelease>` → `activate(true, true)` → `enter_at(row, x, insert)` path
  (the default render="focus" case — the click lands on the mirror), and a
  normal-mode-only `<LeftRelease>` map on each float buffer (visible
  render="always" floats take clicks natively; n-mode-only means a
  drag-selection's release, visual mode by then, never fires it). Clicks past
  EOL append (`startinsert!`; enter_at compares the cell to the line width,
  the native map uses `getmousepos().coladd`). 7 specs in subwin_spec
  ("click to insert"); the docs playground editor opts in with
  `insert_on_click = true` on its raw_buffer.
- [x] Mirror/entry desync on scrolled widgets — DONE (2026-07-04, reported
  from the playground: focusing an editor "teleports" the cursor). Three bugs
  of one family in subwin.lua, all "translated through buffer coordinates
  where screen coordinates were meant":
  - `enter()` mapped root cell → buffer line as `row - c.y + 1`, assuming the
    widget shows its buffer from line 1 — wrong by `base - 1` once the widget
    has scroll state of its own (which is exactly what the mirror renders
    from); same for the column vs the widget's own `leftcol`. Now composes
    `entry.base`/`entry.leftcol` (and the click-to-insert past-EOL check uses
    the composed cell).
  - `exit_dir()` had the mirror image: horizontal exits kept the BUFFER row
    (`c.y + lnum - 1`), vertical exits the buffer column — now both translate
    through base/leftcol and clamp into the box.
  - `reposition()` only updated `entry.clip`/`entry.lclip` in the unfocused
    branch, but a page scroll resizes a FOCUSED float too (set_config always
    runs) and nvim re-anchors its topline around the cursor. The leave-time
    reconstruction `base = topline - clip` then subtracted a stale clip — a
    phantom scroll the mirror rendered (the next unfocused reposition
    cancelled the error again, which is why it looked intermittent). Clip
    bookkeeping now tracks the applied geometry unconditionally; the view
    itself is still never touched while focused.
  4 specs in subwin_spec ("entry/exit through a scrolled widget"). Spec
  gotcha discovered on the way: a red spec aborts before its
  `handle.unmount()`, so mounts leak into later specs — the winid-pattern
  assertion in "WinScrolled resync is wired" fails for any red spec ABOVE it
  in the file; heals at green.
- [x] WRAP teleport ("directly going `i` teleports a few lines", 2026-07-04):
  the fourth member of the family, and the one the playground actually hits —
  raw_buffer WRAPS by default (the playground editor passes no `wrap`), and
  under wrap one buffer line occupies several box rows, so `enter()`'s
  base-arithmetic row→line mapping is off by one line per wrapped row above
  the cursor (any code line wider than the editor content — guaranteed on
  narrow viewports where the editor squeezes below 80). Fix: `enter()` and
  `exit_dir()` translate through `entry.mirror_map` — the per-box-row
  {lnum, cell0} record mirror() already builds, i.e. literally "land where
  the mirror says the user is looking" — with the base/leftcol arithmetic
  kept as fallback for blank padding rows and never-mirrored widgets. 2 more
  specs (wrapped entry, wrapped horizontal exit); suite 267/0. Known
  remaining divergence (accepted, pre-existing): a top-clipped WRAPPED
  widget's REVEAL composes `topline = base + clip` in buffer lines while the
  clip is display rows — the revealed float can show a slightly different
  slice than the mirror did; the cursor still lands on the mirror-correct
  line (set_cursor re-scrolls the float to it).
  - **Momentum/fling scrolling**: in the DOM-free mouse adapter (TDD'd, 13/13
    node tests): touchmove samples a smoothed velocity; releasing above 0.25
    px/ms keeps scrolling with v(t) = v₀·e^(−t/325ms) integrated in closed
    form per animation frame (frame pacing can't change the distance),
    draining px into wheel ticks at the release cell. A finger during a fling
    stops it and is consumed (no accidental click); touchcancel (pinch start)
    abandons the gesture. `now`/`schedule` are injectable — the unit tests
    drive a fake clock.
  - **Pinch-zoom**: two fingers rescale the font px (clamped 8–40, live) via
    the new renderer.setFontPx (re-measures cells, resizes + redraws the
    canvas), mutates the adapter's cell metrics in place, and debounce-fires
    `nvim_ui_try_resize` so the grid re-fits the viewport at the new density.
- [x] Loading indicator — DONE (2026-07-04): `#loader` overlay (logo, gradient
  progress bar, status line); nvim.wasm + tarball downloads stream through a
  counting TransformStream (Content-Length-aware — determinate bar when known,
  shimmer + byte count when not), compile/unpack phases shimmer; hidden when
  the editor goes live.
- [ ] Keyboard-theft mitigation: design navigation around Vim primitives
  (leader, arrows, buffer-local hotkeys) — avoid browser-reserved
  `Ctrl+W`/`Ctrl+N`
- [x] Viewport stabilization CSS — DONE (2026-07-04): `touch-action: none`,
  `user-select: none` (+ webkit variants), `overscroll-behavior: none`,
  tap-highlight suppression on html/body/#gridwrap/#grid;
  `maximum-scale=1, user-scalable=no` in the viewport meta (the guest owns
  pinch now).
- [x] Unsupported-browser UX — DONE (2026-07-04): the JSPI printout replaced
  by a styled `#nosupport` card: Chrome/Edge/Chromium 137+ or Firefox 152+
  work out of the box, Firefox 139–151 needs
  `javascript.options.wasm_js_promise_integration` in about:config + full
  restart, Safari unsupported; the headless `nvim --version` proof-of-life
  streams into the card.

### IMPORTANT: NEW UI HOST

The current nui-host is insufficient for a web application (and also not great
as a neovim UI host). We need a new UI host that truly feels "neovim-native",
satisfying the following:

- Layouts render _inline_ into the parent buffer; that is, layouts don't
  automatically create new float windows.
- Most components also render directly into the parent buffer:
  - e.g. Buttons, checkboxes, text labels and paragraphs can render inline into
    the parent buffer via text and extmarks (which ought to be ummodifiable)
  - Exceptions are for example:
    - a dedicated "raw buffer" component that renders a subbuffer in a float
      (like components do in nui-host) and gives control of the buffer to the
      user,
    - Any text input elements need their own buffer as they do right now
- Components should support a "box model" like in css:
  - Border, inner margins, outer margins. Each should be configurable "per
    direction" if needed (i.e. border only on left and right with specific
    characters, no borders up and down)
  - Highlights on hover and such are desirable. The vim cursor determines the
    hover and "click"/interaction (e.g. with checkboxes and buttons)
- Mouse integration is a plus (can be a follow-up task if complicated)
- Native vim buffer scrolling is respected and leveraged to make the UI "feel"
  native. Since most components are rendered inline, they scroll naturally.
  - For "subbufer" type components, they act as if they occupied a space in the
    parent buffer, and scroll accordingly (their floats move when the parent
    buffer is scrolled). They need to support partial and full occlusion
- Native cursor motions are respected and the primary way of navigating.
  - <C-w>-hjkl when focused in a subbufer will move the focus to either the
    parent buffer
  - hjkl (and other motions like <C-u>/<C-d>) in normal mode in a subbuffer
    navigates within the buffer as expected, unless the motion would bring the
    cursor to a parent buffer (i.e. if the cursor is already at the "end" of the
    buffer in the given direction), in which case they move to the buffer that
    exists in that direction. When in a parent buffer, navigating to a position
    in the buffer occupied by a mounted subbuffer will move the focus onto that
    subbuffer.
  - ...and so on. Essentially the UI should "feel" native.
- Obviously this means we'll need to do our own layouting. Let's keep it
  relatively simple but powerful. We need composable row/column layouts, with
  align/justify support, and box-model support as I previously specified. We can
  discuss this further if more details are needed.
  - Very open to discussion on this, but I think we'd need a two-pass layouting:
    - Bottom-up "measure()" pass
    - Top-down "layout()" pass
- Example. Suppose our component tree has these components:
  ```
  Rows
    Columns
      label
      checkbox
      checkbox
    TextInput
  ```
  And we're mounted on a split pane. Then the only physical neovim windows we
  have are
  - Split pane
  - Floating window covering the full split pane (UI root)
    - TextInput float window in the correct position in the parent buffer
- Performance is important. Let's add benchmarks

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
  1. width AND height fixed (classic Neovim UI) → vertical grow/justify apply,
     content is bounded. Engine API:
     `layout.compute(tree, { width = w, height = h|nil })` — nil height = scroll
     mode (root height = content height, vertical grow/justify inert), fixed
     height = app mode.
- **Subwindow strategy: clipping first.** Partial occlusion = resize the float
  to its visible rows + re-anchor its viewport; fully occluded = hide. Known
  accepted artifact to evaluate: WinScrolled fires post-redraw, so floats lag
  the parent scroll by one frame ("swim"). If that proves annoying for text
  inputs, the *maybe-later* optimization is float-on-focus (inline placeholder
  when unfocused, float materializes on focus) — rejected as the default because
  an inline placeholder can't reproduce native wrapping of multiline float
  content. The clipping engine is needed for `raw_buffer` regardless.
- **Perf posture:** full measure + repaint per commit is acceptable to start;
  cache display-width lookups (`nvim_strwidth` per cell adds up); keep
  damage-tracking (repaint only dirty subtrees) in the back pocket, don't build
  it up front. Benchmarks (task 7) gate this.

#### Module plan — `lua/fibrous/inline/`

- `box.lua` — box-model resolution: per-side margin/padding/border
  normalization, border char sets
- `layout.lua` — pure two-pass engine: bottom-up `measure(node, max_w)`,
  top-down `layout(node, rect)`; row/col with grow/align/justify/gap
- `canvas.lua` — cell-grid painter → buffer lines + highlight spans
  (multibyte-safe)
- `render.lua` — laid-out tree → canvas: borders, padding, per-component
  painters
- `host.lua` — HostConfig: fiber tree → layout tree → commit into the root float
  buffer (extmarks, hit-map)
- `components.lua` — primitives:
  `rows, cols, label, paragraph, button, checkbox, text_input, raw_buffer`
- `interact.lua` — cursor-driven hover highlights + `<CR>`/`<Space>` activation
  via hit-map
- `subwin.lua` — subwindow floats: layout-driven position, scroll sync,
  partial/full occlusion, focus handoff
- `mount.lua` — floating + split mount targets (both create the root float;
  resize sync; teardown)

#### Task breakdown

- [x] 1. Layout engine core (pure Lua, TDD): box model, measure/layout passes,
  row/col grow/align/justify/gap, text wrap under width constraint
  - `lua/fibrous/inline/box.lua` + `layout.lua`; specs
    `tests/inline/box_spec.lua` (13) + `layout_spec.lua` (19). Grow =
    flex-basis-0 shares (remainder to last); explicit width/height are
    border-box and win over stretch; scroll mode makes vertical grow/justify
    naturally inert.
- [x] 2. Canvas renderer: cell grid → lines + highlight spans; per-side border
  drawing with custom chars; multibyte-safe
  - `lua/fibrous/inline/canvas.lua` (cell grid; byte-indexed merged hl spans for
    extmarks; wide-char cells with continuation handling) + `render.lua` (bg →
    border → content paint order; corners only where both adjacent sides exist;
    text cropped to its content box). Specs: `canvas_spec.lua` (8) +
    `render_spec.lua` (9).
- [x] 3. Inline HostConfig + root-float mount targets (floating + split), resize
  sync, teardown
  - `lua/fibrous/inline/host.lua` (HostConfig: whole fiber tree → layout.compute
    → render.paint → ONE host-owned unmodifiable scratch buffer, lines +
    extmarks in ns `fibrous_inline`; size read from injected `get_size` at every
    flush; `relayout()` re-flushes without re-rendering; `host.tree` keeps the
    laid-out tree with fiber backrefs for the task-6 hit-map) + `mount.lua`
    (`floating` = editor-relative root float, `split` = pane + covering
    relative="win" float; `mode = "fixed"|"scroll"`; coalesced
    WinResized/VimResized sync; WinClosed on pane or float tears the app down).
    Specs: `host_spec.lua` (8) + `mount_spec.lua` (7).
- [x] 4. Subwindow clipping risk-spike (pulled forward): one text_input float
  positioned by layout, scroll sync on WinScrolled, resize+re-anchor clipping,
  hide on full occlusion
  - `lua/fibrous/inline/subwin.lua`: text_input is laid out (and border/bg
    painted) INLINE; its content box is covered by an editable zindex-60 float
    keyed by fiber instance. Repositioning subtracts the root's topline
    (relative="win" floats anchor to the window grid, not scrolled content);
    partial top-clip resizes to visible rows + winrestview-scrolls the float's
    own topline; full occlusion → `hide = true`. WinScrolled (pattern = root
    winid) resyncs, synchronous/uncoalesced to minimize the swim. host.lua
    collects `host.subwins` per flush + `on_flush` hook; mount targets attach
    the manager and tear it down. Specs: `subwin_spec.lua` (6). Value seeding
    from props.value on create only (buffer = source of truth after);
    on_change/focus wiring is task 7.
  - [x] 4b. EVALUATE THE SWIM — verdict (2026-07-02, interactive eval): **no
    visible swim**; clipping strategy stays, float-on-focus stays a deferred
    task-10 option. Two feedback items from the eval: full-line hover on
    button/checkbox (fixed — see task 6 note) and no navigation into/out of
    subwindows yet (= task 7 scope, now unblocked).
- [x] 5. Component painters: label, paragraph, button, checkbox (unmodifiable
  inline content)
  - `lua/fibrous/inline/components.lua`: thin function components over the
    `text` host leaf (reconciler/host untouched). Prop mapping: `hl` =
    foreground (→ text_hl), `bg` = background fill (→ node hl); box/layout props
    pass through. button = `[ label ]`, checkbox = `[x]/[ ] label`; both forward
    handlers + a `role` marker onto node props (what the hit-map reads).
    Re-exports col/row/text/text_input. Specs: `components_spec.lua` (7).
- [x] 6. Cursor interaction: hit-map, hover highlight, `<CR>`/`<Space>`
  activation on the component under cursor
  - `lua/fibrous/inline/interact.lua`: hit-map = pure walk of `host.tree` for
    the deepest node with a `role` under the cursor (reverse child order = paint
    order; role-less subtrees fall through to the closest interactive ancestor —
    containers can be interactive). Hover paints the node's rect with `hover_hl`
    (default CursorLine) in its own namespace at priority 4200, re-evaluated on
    CursorMoved AND after every flush. `<CR>`/`<Space>` buffer-local: button →
    on_press(), checkbox → on_toggle(not checked). Wired into both mount targets
    alongside the subwin manager. Specs: `interact_spec.lua` (5). The
    `inline_scroll` example now demos hover/activation too. **Post-eval fix
    (2026-07-02):** button/checkbox used to stretch to the container width
    (default cross-axis align), so hover lit the whole line; added per-child
    `align_self` to the layout engine (overrides container `align`) and both
    widgets now default to `align_self = "start"` — hover hugs the widget; pass
    `align_self = "stretch"` or a `width` for full-width widgets.
- [x] 7. Subwindow engine (full): raw_buffer, focus traversal (edge motions
  hjkl/`<C-u>`/`<C-d>`, `<C-w>`-hjkl, parent-cursor entry into subwindow
  regions)
  - **(Superseded 2026-07-04** — see "Subwindow focus rework": traversal-in is
    REMOVED; focus is explicit via `<CR>`/click/insert-keys. Exits below
    unchanged.) Focus traversal (`subwin.lua`): IN — CursorMoved on the root
    buffer (only when the root float is current); cursor cell inside a subwin's
    content box focuses its float at the corresponding cell. OUT — buffer-local
    n-mode maps per float buffer: `h/j/k/l` at the buffer edge exit into the
    root adjacent to the widget's border box, keeping the cursor's row/col
    alignment (non-edge → native motion, count preserved via `v:count1`);
    `<C-w>h/j/k/l` exit unconditionally; `<C-d>/<C-u>` always hand focus AND the
    motion to the root (page motions never trapped). Exits whose target is
    outside the root buffer are no-ops — staying put beats the root clamping the
    cursor straight back into the widget (re-entry loop). Specs:
    `focus_spec.lua` (5).
  - text_input wiring (`subwin.lua`): `props.on_change(value)` via
    **nvim_buf_attach on_lines** — NOT TextChanged/TextChangedI (main-loop
    events; never fire inside a feedkeys batch). on_lines runs under textlock,
    so the handler is `vim.schedule`d + coalesced per edit burst. `<CR>` (n+i,
    buffer-local): `props.on_submit(value)` when given; otherwise insert-mode
    `<CR>` feeds a literal newline (flags "in": before remaining typeahead,
    noremap). Handlers read off `entry.node.props` at fire time (latest
    committed). Guard: `reposition()` skips its winrestview while the float is
    the current window — otherwise the on_change → re-render → resync path yanks
    the cursor to col 0 mid-typing (covered by the clobber spec). Specs:
    `input_spec.lua` (4).
  - raw_buffer (`components.lua` + `host.lua` + `subwin.lua`): `ui.raw_buffer`
    subwindow leaf showing a caller-provided `props.bufnr` — UNOWNED: unmount
    removes our keymaps/autocmds but leaves the buffer alive (no bufnr → owned
    scratch, destroyed as usual). Default height = the buffer's line count
    (measured as N-1 newlines); explicit `props.height` wins.
    `props.wrap ~= false` → native wrapping escape hatch (text_input stays
    nowrap). Traversal callbacks fall back to native motions when the buffer is
    shown in a non-float window. Specs: `raw_buffer_spec.lua` (4).
  - `width.lua` gained shared `cell_to_byte` (moved from interact.lua; the
    traversal needs it for cursor placement). Suite after: 138 passed + the 2
    pre-existing relayout failures.
- [x] 8. Benchmarks (`make bench`): full commit for N components, incremental
  update, scroll-sync tick
  - `bench/run.lua` (headless, isolated; `make bench` /
    `make bench BENCH_N=500`). Scenarios: pure layout+paint, mount, full
    re-commit (set_props), incremental update (one leaf use_state), scroll tick
    (WinScrolled subwin resync). Numbers at N=100 sections (~600 nodes, this
    machine, headless): pure layout+paint 2.5ms · mount 7.7ms · full re-commit
    7.7ms · incremental 7.6ms · scroll tick 0.007ms. Perf work the bench forced
    (suite-guarded refactors): `width.lua` (memoized char widths + ASCII fast
    path — nvim_strwidth API overhead dominated), canvas rewritten to parallel
    per-row arrays (was a table per cell; alloc dominated), border edges via
    direct put. Before: full commit ~36ms. Damage tracking stays in the back
    pocket — remaining commit cost is reconciler + set_lines + ~2k extmarks,
    fine at realistic tree sizes.
- [x] 9. Migration: port examples + welcome panel + fibrous-docs site; delete
  nui_host + vendored nui (2026-07-03)
  - Public API (`lua/fibrous/init.lua`): `M.mount` = inline `mount.floating`,
    `M.mount_split` = `mount.split`, `M.mount_window` = `mount.window`, `M.ui` =
    the inline component set. `mount_as_window_host`, `M.components` and
    `M.hooks.use_keymap` are gone. Pinned by `tests/inline/api_spec.lua` (2).
  - Examples ported to the inline host: `hello` (bordered col of labels),
    `counter` (buttons via hit-map + the external-keymap actions pattern),
    `form` (text_input on_change/on_submit, cursor lands in the input via
    focus-follows-cursor), `sidebar` (cursor-driven list: plain labels given
    `role`/`on_press`/`hover_hl` — the hit-map needs only a role), `panel` (ACP
    shell: flex layout, `use_plan` custom hook, plan = checkboxes replacing the
    old scoped keymaps, prompt on_submit clears its own buffer — it IS current
    when the handler fires). All 7 examples smoke-tested headlessly (mount →
    non-blank render → unmount).
  - Deleted: `lua/nui/**` (vendored), `lua/fibrous/dom/` (nui_host),
    `lua/fibrous/mount/` (floating + window_host), `lua/fibrous/components/`,
    `lua/fibrous/hooks/` (use_keymap — its "bind across subtree leaf buffers"
    concept has no counterpart in the one-buffer inline host; cursor + hit-map
    replace it), `tests/{dom,mount,hooks}/` (incl. the 2 pre-existing failures).
    `fiber.scoped_keymaps` field removed; stale nui references in
    comments/README/examples cleaned.
  - fibrous-docs (`../fibrous-docs`) already runs on
    `fibrous.inline.mount`/`mount.window` — nothing to port there (its flake
    comment still says "with its vendored nui"; harmless, worth touching up on
    the next site change).
  - Suite after: **116 passed, 0 failed** (full run == per-file sum; first fully
    green suite).
- [x] 10. Mouse integration — DONE (2026-07-03). Design: the mouse only ever
  MOVES THE CURSOR; hover/focus/activation stay one cursor-positional concept
  (no parallel pointer-hover state, which would double the style states and
  muddy `<CR>` semantics).
  - Terminal side (`interact.lua`, `opts.mouse` on all three mounts —
    `{ activate?, follow? }` or `false`): Neovim's default `mouse=nvi` already
    moves the cursor on click, so hover-follows-click and
    click-into-subwin-float are native and free. `activate` (default true) =
    buffer-local `<LeftRelease>` firing the same path as `<CR>`; release not
    press, and only in normal mode — a drag lands in visual mode, so
    drag-selections never activate. `follow` (default false) =
    focus-follows-mouse: sets the GLOBAL 'mousemoveevent' (saved/restored on
    unmount) + `<MouseMove>` map moving the cursor to `getmousepos()` — only
    when the pointer is inside the root win, never yanking the cursor out of a
    subwindow. No global `mouse` option touched, ever.
  - Specs (`interact_spec.lua` +4) drive the maps at the KEY level:
    `nvim_input_mouse` is useless headless — without a UI grid, `mouse_find_win`
    can't resolve screen positions to floats, so synthesized clicks never reach
    the root float (getmousepos() returns the underlying window). Verified
    end-to-end instead in a live kitty TUI via the nvim MCP server: real
    `nvim_input_mouse` click → float focused, cursor on the button cell,
    on_press fired.
  - Web side (`../nvim-wasm-core`): `web/mouse.js`, a DOM-free adapter (px→cell
    math, per-cell move/drag dedupe, wheel px-accumulation into one tick per
    cell) wired in `main.js` to `nvim_input_mouse` (grid 0); node-unit-tested
    red-green by new `checks.web-mouse-unit` (8 tests). Guest semantics
    (click-to-activate etc.) are fibrous', identical to the terminal — the
    client only forwards faithfully.
  - Follow-up parked: float-on-focus text inputs if scroll-swim warrants it.
    (Shipped 2026-07-04 as `render = "focus"` — see "Subwindow focus rework".)
- [x] Bugfix (2026-07-03): root scrolls clobbered a subwindow's own
  scroll/cursor. `reposition()`'s occlusion re-anchor ran
  `winrestview({ topline = clip+1, lnum = clip+1, col = 0 })` unconditionally on
  unfocused floats — it OWNED the viewport, valid only for widgets with no
  scroll state of their own; a taller-than-window editor (raw_buffer) lost its
  place (and cursor) on every root scroll. Now the clip COMPOSES: `base` (the
  widget's own scroll) is reconstructed as displayed-topline − last-applied-clip
  (`entry.clip`), captured BEFORE `nvim_win_set_config` (a height shrink makes
  nvim re-anchor topline around the cursor, polluting the read — this cost a
  debug round); applied view = base + clip with cursor/columns preserved (lnum
  only dragged enough to keep topline valid). Focused floats stay untouched as
  before. Spec: subwin_spec +1 (internal scroll at topline 4, root clip composes
  to 5, unclip restores 4, cursor {5,1} intact). Suite: 189 passed, 0 failed.
  after focusing ("floating window cannot be relative to itself") — the raw 0
  was stored and re-resolved at sync time, when the current window is the root
  float. Now resolved to a concrete winid at mount time (also fixes the
  WinClosed teardown pattern and pane-size reads, which read "current window"
  too). Spec: mount_spec +1. Suite: 178 passed, 0 failed (2026-07-03)
- [x] Bugfix: the focused-input border accent never showed in real use —
  entering an input by MOVING THE CURSOR into it goes through the traversal
  CursorMoved autocmd, which wasn't `nested`, so the WinEnter that applies
  `_focus` was silently swallowed (the specs all drove nvim_set_current_win from
  test context, where autocmds fire normally — that's why they were green). Fix:
  `nested = true` on the traversal autocmd, subwin.lua. Spec: style_state_spec
  +1, enters via cursor traversal. (2026-07-03)
- [x] Bugfix: hjkl exits from a bordered input jumped PAST the border —
  `exit_dir` stepped adjacent to the border box (`r.x - 1` / `r.x + r.w` …)
  while entry crosses the border one keypress at a time. Exits are now
  content-box adjacent (`c.x - 1` / `c.x + c.w` …): with a border that IS the
  border cell — symmetric with entry; borderless inputs are unchanged (content
  == rect there). Spec: focus_spec +1 (bordered input, all four directions).
  Gotcha surfaced while writing it: `height` sizes the BORDER box, so
  `height = 1` + `border = true` is degenerate (both border rows collapse, the
  float hides). (2026-07-03)
- [x] `:q` on a subwindow float now closes the WHOLE app (decision: no reopen,
  no half-open state), exactly like `:q` on the root — a WinClosed watcher in
  subwin.lua closes the ROOT float (deferred; windows can't be closed from
  inside WinClosed), which cascades into the mount target's teardown. Our own
  reconcile/teardown closes set `entry.dead` before closing, so they don't
  rebound. Spec: subwin_spec +1. Suite: 184 passed, 0 failed. Smoke:
  examples/inline_fullscreen headless — traversal into the input paints 4
  FibrousBorderFocus border marks; :q in the input tears the whole app down.
  (2026-07-03)

### Style rework

A principled approach to styling + state-based style overrides, resolved OUTSIDE
the render cycle (today's hover overlay, generalized). Also: styling portions of
a paragraph, and border-embedded titles.

#### Decisions (2026-07-03)

- **`style` prop on all components.** Base style keys live directly in the
  table; state overrides are `_`-prefixed sibling keys:
  ```lua
  style = {
    hl = "Normal",                               -- base
    _hover = { hl = "Visual", border = "double" },
    _focus = { border_hl = "Title" },
  }
  ```
  Flat `_hover`/`_focus` keys (NOT `states = { hover = ... }` nesting — dev-ex
  over purity; the key set is closed and unknown keys error loudly).
- **States: `_hover` and `_focus` only** (hover = cursor inside the hit rect,
  from interact.lua; focus = subwindow float holds the cursor, from subwin.lua).
  `_active` is DEFERRED until it means something in a cursor-driven UI (`<CR>`
  is instantaneous; a timed press-flash is not worth inventing yet).
- **Combination = fixed precedence + key-wise merge:** `base ← _focus ← _hover`,
  later wins per key. No compound state keys; nested state tables
  (`_hover = { _focus = ... }`) are the extension path if a real need appears.
- **Resolution happens at paint time** from committed props + interaction state
  — components never re-render (and the reconciler never runs) on a state
  change. `inline/style.lua` is a pure module (merge, precedence, key
  classification, validation): unit-testable without Neovim, like box.lua.
- **Two invalidation tiers**, classified per-key at resolution:
  1. hl-only delta → extmark overlay in the hover namespace (no relayout, no
     repaint — today's fast path, kept as the common case);
  1. anything structural (margin/padding/border sides/chars, width/height) →
     relayout + repaint (~2.5ms). SUPPORTED, not just tolerated — users will
     expect it — with a documented caveat: box-metric changes on hover shift
     layout under the cursor and can un-hover the node (CSS hover-jank).
- **Naming stays CSS:** `padding` / `margin` (NOT inner/outer_margin — the
  codebase, specs and everyone's muscle memory already use the CSS names).
  box.lua's per-side normalization (SidesSpec x/y shorthands, per-side border
  chars/enables) is reused as-is.
- **hl groups: three, not four.** `style.hl` (background fill over the border
  box), `style.text_hl` (foreground), and for the border: the border spec's own
  `hl` for the base, plus a top-level **`border_hl`** recolor key (wins over the
  spec's hl). border_hl exists so state overrides stay atomic per key —
  recoloring a border on focus doesn't deep-merge into the border spec, and it
  classifies as hl-tier (fast path) while a full `border` override is
  structural. No separate padding hl — CSS backgrounds cover the padding box
  too; nest a container if you really want it.
- **Existing flat props** (`hl`, `bg`, `hover_hl`, `border`, `padding`,
  `margin`) remain as base-style sugar during migration; `hover_hl` becomes
  sugar for `style._hover.hl`.
- **Border titles:**
  `BorderSpec.title = { text, hl?, align? = "left"|"center"|"right", pos? = "top"|"bottom" }`,
  painted over the edge by render.draw_border after the edge chars. Min-width
  rule: a bordered node ≥ title width + corners. Replaces the panel example's
  `titled()` helper.
- **Rich-text spans ≠ inline flow layout — split.** Committed: `paragraph` (and
  `label`) accept span lists —
  `text = { { "plain " }, { "loud", hl = "Title" } }` — with the wrap algorithm
  carrying hl attribution through to per-line canvas spans. Span-level hit rects
  (links inside a paragraph) are a later extension of the same data. A full
  inline flow layout (components wrapping like words: line boxes, baselines) is
  explicitly PARKED pending a concrete use case spans can't cover.

#### Task breakdown

- [x] S1. `inline/style.lua` (pure, TDD): style-table normalization, state merge
  \+ precedence, structural-vs-hl key classification, unknown-key validation;
  flat props resolve as base-style sugar (2026-07-03)
  - `normalize(props)` once per commit: style table over flat sugar (`hl`,
    `text_hl`, `border`, `padding`, `margin`, `hover_hl` → `_hover.hl`); base
    box keys fully resolved via box.lua, state partials carry only the keys they
    mention (each resolved). `apply(norm, states)` at paint time → resolved
    style + delta tier `nil`/`"hl"`/`"structural"` (tier counts key presence,
    not value diffs; result shares subtables — treat as immutable). `border_hl`
    added per the decision above. Spec: `style_spec.lua` (12). Suite: 129
    passed, 0 failed.
- [x] S2. State plumbing: interact (hover) + subwin (focus) feed paint-time
  resolution; hl-only fast path via overlay extmarks; structural path = relayout
  \+ repaint; port `hover_hl` users (2026-07-03)
  - Host: weak-keyed `states` map + `set_state(fiber, name, on)` (records only —
    callers decide when to relayout); `build_node` attaches `node.style`
    (normalized) and `node.style_resolved` (`apply` when states are active, else
    the shared base — no copy). layout/render read `style_resolved` with a
    `box.resolve(props)` / `props.hl` fallback so raw trees (unit tests) still
    work.
  - interact.lua: hover = `style._hover` (default `{ hl = "CursorLine" }`;
    `hover_hl` ported via normalize sugar, no call-site changes). hl tier →
    overlay extmarks (hl/text_hl/border_hl cell-accurate, priority 4200);
    structural tier → `set_state` + relayout, settle loop (cap 3) re-hits
    against moved rects, `syncing` flag breaks the on_flush re-entry.
  - subwin.lua: WinEnter/WinLeave on the float wire `_focus` (always the
    structural path — rare); guarded on current-win identity and `entry.dead`.
  - Spec: `style_state_spec.lua` (5: border/hl base via style table, hl-only
    hover overlay + clear, structural hover border swap + revert, focus
    border_hl on subwin enter/leave). `style_spec.lua` grew a tier test (13).
    Suite: 135 passed, 0 failed; bench flat (layout+paint 2.1ms, re-commit
    7.7ms).
- [x] S3. Border titles (BorderSpec.title + renderer + min-width rule); port the
  panel example off `titled()` (2026-07-03)
  - box.lua: `BorderSpec.title = { text, hl?, align? = "left", pos? = "top" }`
    (bare string = `{ text = ... }` sugar), validated loudly. The table form
    also gained a positional preset (`border = { "rounded", title = ... }`) —
    without it, preset + title needed hand-written corners; side keys still opt
    out (`= false`) or override chars.
  - render.draw_border paints the title over its edge between the corners (crop
    to the span, align offsets), `title.hl or` border hl (so a state's
    `border_hl` recolors an hl-less title too). layout.measure floors the
    intrinsic width at title + left/right border; explicit `width` wins and the
    renderer crops instead.
  - panel example: `titled()` label-row hack replaced by a `titled_border()`
    border spec at the three call sites (Session height 6 → 5 — the caption no
    longer costs a content row). Specs: box_spec +5, render_spec +4, layout_spec
    +2. Suite: 146 passed, 0 failed.
- [x] S4. Rich-text spans in paragraph/label: wrap carries per-span hl into
  canvas spans; hit-map span rects deferred until links are needed (2026-07-03)
  - `text` may be a span list — bare strings or `{ "chunk", hl = ... }` tables,
    e.g. `{ "plain ", { "loud", hl = "Title" } }`. New pure `inline/spans.lua`:
    `flatten` → full text + byte-indexed hl ranges (invalid spans error loudly),
    `runs` re-attributes an output line's source pieces back to the ranges.
  - layout threads source offsets through the wrap (a join space takes the hl of
    the gap it replaced; hard-broken chunks map 1:1); `node.line_runs` parallels
    `node.lines` and is only built for span text — plain strings take the old
    path with no extra allocation. render paints per run, hl-less runs falling
    back to the node's `text_hl`.
  - Specs: spans_spec (3), layout_spec +3, render_spec +3, components_spec +1.
    Suite: 156 passed, 0 failed; bench flat (re-commit ~8.2ms vs ~7.9 — the wrap
    loop now carries gmatch position captures).
- [x] S5. Default theme: one module owning all default styles (hl groups AND box
  defaults like the border preset), with an out-of-the-box look (2026-07-03)
  - Decisions (2026-07-03): new `inline/theme.lua` is the single home for
    defaults — (1) `theme.groups`: namespaced `Fibrous*` hl groups defined with
    `nvim_set_hl(0, ..., { default = true })` so colorschemes/users override
    freely, re-applied on ColorScheme, `theme.apply()` invoked from
    `host.new()`; (2) `theme.styles`: style-shaped default tables (same schema
    as `props.style`, `_hover`/`_focus` included) keyed by a `theme` node prop —
    components tag themselves (`theme = "button"`), users can tag any node or
    opt out with `theme = false`, unknown keys error;
    `style.normalize(props, defaults)` seeds them at the LOWEST precedence
    (theme < flat props < `props.style`, key-wise); (3) `theme.border_preset`
    names what `border = true` (and `side = true`) means — default "rounded".
    Scattered literals move onto themed groups: render's FloatBorder →
    FibrousBorder, interact's CursorLine hover → FibrousHover; border titles
    default to FibrousTitle at normalization (a title no longer inherits the
    border's hl — standard float-title look; border_hl recolors only the frame).
  - Concrete defaults: FibrousBorder→FloatBorder, FibrousTitle→FloatTitle,
    FibrousHover→CursorLine, FibrousDim→Comment, FibrousButton→Pmenu,
    FibrousButtonHover→PmenuSel, FibrousCheckboxMark→Special. Buttons get a
    Pmenu chip background + PmenuSel hover; checkbox marks render as spans
    (`[x]` accent when checked, `[ ]` dim when not); `border = true` is rounded.
  - Implementation: `theme.lua` exported as `fibrous.theme`; `theme.apply()`
    from `host.new()` + ColorScheme autocmd. `style.normalize` grew the
    `defaults` param (theme resolved first via the same closed-key validation —
    bad theme entries error like bad styles); unknown `theme` keys error at
    build_node. Panel example leans on the defaults (`border = true` prompt,
    `FibrousDim` status, title hl dropped from `titled_border`). Specs:
    theme_spec (4), style_spec +4, components_spec +6 (chip/hover default,
    prop-over-theme precedence, `theme = false` opt-out, checkbox marks,
    any-node opt-in, unknown-key error), box/render/subwin expectations moved to
    the rounded default. Suite: 170 passed, 0 failed; bench flat (re-commit
    ~6.9ms).
- [x] S6. De-hardcode the widget glyphs: button brackets become a themed border,
  checkbox marks become a prop-overridable theme surface (2026-07-03)
  - Decisions (2026-07-03): the button's `[ ]` move out of the text into
    `theme.styles.button` as a transparent left/right border
    (`border = { left = "[", right = "]", hl = false }` + `padding = { x = 1 }`
    — same 6-cell footprint). New border spec value `hl = false` = TRANSPARENT:
    render paints those cells with no hl of their own, so they keep the node's
    background fill (canvas put-with-nil semantics) — brackets take `bg`
    overrides and the hover overlay exactly like the old baked text.
    Consequences, both deliberate: an explicit border prop REPLACES the brackets
    (box keys are atomic — `border = true` on a button now means a real rounded
    box around the bare label), and `theme = false` drops the brackets entirely
    (a bare-label starting point for wrapper components). Checkbox marks are
    CONTENT, not style (closed style key set stays closed): new theme surface
    `theme.marks.checkbox` (`checked`/`unchecked` mark spans), overridden
    KEY-WISE per instance by a `marks` prop on the component — the
    wrapper-component customization path.
  - Specs: box_spec +1 (`hl = false` passthrough), render_spec +2 (transparent
    border inherits the fill / stays unhighlighted over no fill), theme_spec +2
    (chip shape, marks surface), components_spec +2 new (custom bracket chars by
    border prop, key-wise marks override) and 5 updated
    (root/boxed/opt-out/opt-in button expectations, chip census). Suite: 177
    passed, 0 failed; bench flat (re-commit ~6.6ms). Headless smoke: default
    chip, `( )` chip, bare label, `[x]`/`[ ]`/custom `*` marks all render with
    the right census.
- [x] S7. Default-look polish: gray borders + focused text_input accent
  (2026-07-03)
  - FibrousBorder relinked FloatBorder → LineNr (a subtle gray in dark AND light
    schemes; FloatBorder usually just takes the float's normal fg); new
    FibrousBorderFocus → Directory (first shipped as CursorLineNr, but that is
    BOLD-ONLY in the stock scheme and bold is invisible on box-drawing glyphs —
    the focus accent needs an actual color, verified fg=#8cf8f7 after apply).
    `theme.styles.text_input = { _focus = { border_hl = "FibrousBorderFocus" } }`
    accents an input's border while its float holds the cursor — rides the
    existing subwin focus wiring (set_focus guards on `style.focus`, which the
    theme now provides).
  - Enabler: a node's theme key now DEFAULTS to its host tag (text_input, text,
    col, row, raw_buffer) when no `theme` prop is given — theme.styles can
    target a whole node kind; a missing entry is simply unthemed, explicit
    unknown keys still error, `theme = false` still opts out. (ui.text_input is
    a raw primitive, so nothing could tag it.)
  - Specs: theme_spec +1 and links updated, components_spec +1 (tag fallback),
    style_state_spec +1 (themed focus accent end-to-end). Suite: 181 passed, 0
    failed; bench flat (re-commit ~7.0ms).

### Subwindow focus rework — explicit focus + text mirror + render policies (2026-07-04)

Decision (2026-07-04, after design discussion): subwindows must NOT capture the
cursor. The old traversal-in (CursorMoved auto-focus) made hjkl-ing past a big
editor traverse its whole content, and focus-steal aborted any visual selection
crossing a widget. New model is Jupyter-like command/edit modes; the common
"type here" flow still costs one keystroke (`i` over the widget).

- [x] F1. Explicit focus: traversal-in autocmd REMOVED; the root cursor glides
  over widget regions. Focus enters only via `<CR>`/click (interact's activate
  path, subwins offered the cell before the role hit-map; `<Space>` stays
  role-only) or i/I/a/A/o/O (root-buffer maps: focus + replay the key inside —
  replayed with feedkeys "in", PREPENDED so batched typing keeps its order).
  `manager.enter_at(row, x)` hit-tests the border box, clamps into content;
  returns false (→ role fallthrough / native E21) when nothing focusable. Exits
  unchanged (edge hjkl, `<C-w>hjkl`, `<C-d>/<C-u>`). Keymap-driven entry fires
  WinEnter naturally — the old `nested` autocmd subtlety is gone. Specs:
  focus_spec rewritten (12), style_state traversal test → `<CR>` entry.
- [x] F2. Text mirror: subwin.lua writes each widget's visible buffer slice into
  the root canvas cells of its content box (reposition captures `entry.base` =
  the widget's own topline; canvas repaints blank each flush, sync rewrites
  after). Honesty layer: the gliding cursor sits on real characters, yank/visual
  get real text. Wrap-aware (`chop()` reproduces the float's wrapping: tab
  expansion by logical vcol, continuation rows, wide-char-at-edge moves whole;
  'linebreak'/leftcol not modeled — style=minimal floats have neither);
  `entry.mirror_map` records (box row → lnum, cell0) for the transcriber.
  Refreshes: every reposition (flush/WinScrolled), nvim_buf_attach on_lines
  (coalesced, skipped while focused), WinLeave (deferred — settles focused
  edits).
- [x] F3. Per-component render policy `props.render = "always" | "focus"`
  (text_input + raw_buffer; default "always" — both stay available to
  experiment, per discussion):
  - "always": float always shown; mirror invisible, NO highlight work.
  - "focus": float hidden unless focused (enter() reveals first — a hidden float
    can't be entered; fully-occluded enter returns false), mirror is the view,
    and `transcribe()` copies the buffer's queryable highlights onto it:
    persistent extmarks (diagnostics, semantic tokens — verified non-ephemeral
    in nvim source — inlay hints, plugin marks; priority +8 above canvas base)
    and regex :syntax via per-cell synID runs (only when `b:current_syntax` is
    set; priority 4100). Refresh rides the mirror triggers +
    DiagnosticChanged/LspTokenUpdate autocmds. NOT copyable by nvim design:
    ephemeral decoration-provider hls (treesitter, indent guides);
    layout-changing features (conceal, inline virt_text, folds) not modeled.
- [x] F4. guicursor shim (`inline/cursorshim.lua`): nvim renders an OBSCURED
  cursor (cell covered by a higher-zindex float) with the REPLACE-mode guicursor
  entry — ui_flush() substitutes mode_change("replace") via
  ui_cursor_is_behind_floatwin() (src/nvim/ui.c; default r=hor20 → underscore;
  verified by pty DECSCUSR capture). While any render="always" widget is live
  the manager holds a refcounted `,r-cr:block` append: glide cursor stays a
  block on the (mirror-guaranteed-real) character. Contract: inert when
  guicursor=="" (never enables shaping); restore only if the value is still
  exactly ours (user/plugin change wins); lifts live when the last always-widget
  leaves the tree. Cost while held: real replace mode shows a block. Spec:
  cursorshim_spec (6).
- [x] F5. Benchmarks (scratchpad mirror_bench.lua; 80x40 raw_buffer over a
  500-line buffer, scroll/edit + relayout per frame): no-subwin baseline 0.27ms
  · render=always (mirror only) ~0.75ms · render=focus no-syntax ~0.6ms ·
  render=focus + syntax transcription ~1.9ms. Verdict: no mirror opt-out needed
  now; if a page ever hosts many large widgets, a `mirror = false` prop is the
  escape hatch (user-approved option, parked).
- Suite: **212 passed, 0 failed** (focus 12, subwin 19, cursorshim 6).
- [x] F6. Follow-up round (2026-07-04, user review): **render="focus" is now the
  DEFAULT** ("always" is the opt-in) — flat page by default: honest block
  cursor, complete visual-selection highlights, no guicursor hold; geometry
  specs pin the always path explicitly. WinEnter now reveals a hidden float
  (verified: `nvim_set_current_win` CAN enter a hidden float and it stays hidden
  — `<C-w>w` cycling would edit invisibly without the reveal). Mirror gained
  horizontal scroll: nowrap widgets render cells \[leftcol, leftcol+w) (wide
  char straddling the cut pads left; mirror_map cell0 = leftcol so transcription
  translates). `theme.styles.raw_buffer` gets the same `_focus` border accent as
  text_input — the brightened border is what marks the edited widget under the
  focus default. Policies examples (repo + site) now linewrap (raw_buffer
  default) with a wrapping comment line and explicit heights. Suite: **215
  passed, 0 failed**.
  - Perf note: the canvas rewrites the WHOLE buffer every flush
    (`nvim_buf_set_lines(0,-1)` in host.flush), so the mirror must rewrite every
    flush too — a skip-if-unchanged guard is only possible together with canvas
    damage tracking (parked with it in the task-8 perf posture).
- Known gaps / parked:
  - Visual selection across a shown float still has a highlight HOLE (the float
    covers the selection hl; content yanked is real now). Possible later
    increment: hide subwin floats while in visual mode ("flatten").
  - Clip composition for a PARTIALLY occluded wrapped widget still counts buffer
    lines, not screen rows (predates this work).
  - Site follow-up: homepage example "Two focus policies" showcases both
    policies side by side on the same lua buffer (`../fibrous-docs` examples.lua
    \+ home_spec TITLES; local tests green 5/5 — the BUILT site needs the usual
    commit+push+flake-lock bump).
  - Repo example: `examples/policies.lua` (`make example EX=policies`), same
    demo standalone; stale "focus follows the cursor" wording updated in
    form/panel examples + examples/README.
- Parked: inline flow layout; `_active` state.

### Subwindow sync bugs + site performance round (2026-07-04, later)

User-reported: (a) horizontal scrolling desyncs floats from the page (seen with
a mac trackpad), (b) submitting a TODO in insert mode leaves insert mode "in the
air", (c) the site needs a native-run flake app + a real-scenario benchmark, (d)
suspected render="focus" extraction lag, (e) a ~1s periodic lag spike (GC
suspected).

- [x] G1. Horizontal root scroll: `reposition()` now offsets floats by the
  root's leftcol as well as topline (the root float is nowrap, so trackpads / zl
  can scroll it sideways) — col shift, left-edge clip with the clip COMPOSED
  into the widget's own leftcol (`entry.lclip`, symmetric with base/clip
  vertically; cursor clamped into the narrowed view so nvim can't re-scroll it
  back), hide when fully off-view. Wrapped floats accept a rewrap divergence
  when horizontally clipped (same family as the vertical wrapped-clip gap).
  Specs: subwin_spec "horizontal root scroll" (3).
- [x] G2. Focused-widget unmount guard: `destroy()` of the CURRENT window now
  stopinserts + deliberately exits to the root at the widget's old origin. The
  TODO demo shape (on_submit inserts a sibling before the text_input →
  positional reconciler recreates it → float closed mid-insert) left the user in
  insert mode over the unmodifiable root. Spec: focus_spec, submit batch with
  the flush landed while insert is active (vim.wait inside on_submit).
  - Parked (nicer UX, needs design): keyed reconciliation (`props.key`) would
    PRESERVE the input across submits (focus + insert survive); today the
    accidental destroy/recreate is also what clears the input — a controlled
    `value` prop (reset buffer when the prop changes across commits) would
    replace that. Decide the wanted submit UX before building either.
- [x] G3. `fibrous-docs` native app: `nix run .#native` — same site/init.lua,
  same webapp modules, fibrous as a pack/start plugin, in a real terminal nvim
  ("is it slow, or slow in wasm"). Defaults to the PINNED fibrous input;
  `FIBROUS_PATH=/path nix run .#native` debugs a local tree without a lock bump.
  Headless-smoked (homepage mounts: root + 9 widget floats).
- [x] G4. `fibrous-docs` homepage benchmark: `nix run .#bench` /
  `nvim --headless -u NONE -i NONE -l tests/bench.lua` — mount, set_props
  re-render, relayout, WinScrolled resync, hover step; BENCH_COLS/LINES/N knobs.
  GOTCHA that hid everything: `-u NONE` leaves syntax OFF, and the transcriber
  skips synID without `b:current_syntax` — early numbers were ~5x too good.
  bench.lua now `syntax enable`s for site parity (headless also needs `wincmd =`
  \+ win_set_height; the sole window ignores lines/columns changes).
- [x] G5. **Extmark leak** (the real source of the periodic-spike growth and
  most of the flush cost): every canvas flush is a whole-buffer
  `nvim_buf_set_lines(0,-1)`, which RELOCATES existing extmarks out of the
  widget's box — `transcribe()`'s box-ranged namespace clear missed them forever
  (+~476 marks/flush on the homepage; frame times grew linearly: relayout
  87→168ms over 30 frames). Fix: clear the whole per-entry namespace. Spec:
  "transcribed highlights do not accumulate across flushes".
- [x] G6. Scroll-path extraction memo: a pure root scroll changes only where
  floats sit — mirror + transcription depend on (base, leftcol, widget
  changedtick, box), so `reposition()` now skips extraction when that key is
  unchanged, unless the frame is `fresh` (on_flush: canvas rewritten) or
  `entry.view_dirty` (DiagnosticChanged/LspTokenUpdate — no changedtick bump).
  WinScrolled passes fresh=false. Spec: "a pure scroll resync reuses the
  extraction" (host changedtick + mark ids stable; widget's OWN scroll still
  re-extracts). This answers the async/cooperative-scheduling idea: the
  scroll-path work is REDUNDANT, not slow — skip beats defer.
- [x] G7. Syntax-run cache: whole-line synID runs cached per entry keyed by
  (changedtick, b:current_syntax); flush frames over an unchanged buffer only
  re-place extmarks. Guard spec: editing the sub buffer refreshes transcribed
  syntax (invalidation via tick).
- Homepage numbers (native, 160x45, syntax on, ~7 focus-policy widgets): | phase
  | before | after | | mount + first paint | 32ms | 32ms | | set_props re-render
  | 53ms avg, growing | ~10ms, stable | | relayout | 129ms avg, growing | ~10ms,
  stable | | WinScrolled resync | ~11ms | **0.03ms** | Micro (72x16
  widget/scroll frame): focus+syntax 2.9ms → 0.01ms.
- [x] G8. The ~1s lag spike (user report): the clock example's 1s timer ticks
  state → full commit + canvas rewrite + all-widget re-extraction every second.
  NOT GC (Lua mem stable 4-8MB across hundreds of frames). Before: ~50ms native
  and GROWING with the G5 leak (wasm: multiples of that — matches "spike every
  second"); after G5-G7: ~10ms native, bounded. Needs the usual push +
  fibrous-docs lock bump to reach the built site.
  - Remaining if wasm still spikes: canvas damage tracking / subtree-scoped
    commit (parked, task-8 perf posture) — the ~10ms is now layout+paint of 306
    lines, not extraction.
- Suite: **222 passed, 0 failed**; fibrous-docs 5/5.

### Canvas damage tracking + nix packaging (2026-07-04, evening)

- [x] H1. **Canvas damage tracking** (pulled out of the back pocket per G8): the
  flush no longer rewrites the whole buffer. `host.lua` retains the previous
  frame's canvas (lines + per-row hl spans), diffs the new frame (equal head +
  equal tail bracket the change), and applies ONE minimal splice: ranged
  `nvim_buf_clear_namespace` BEFORE the write (afterwards the edit would have
  relocated the marks out of the range — the G5 lesson), one ranged `set_lines`,
  extmarks re-set for the spliced rows only. Marks outside the splice survive
  and shift with row-count changes. `on_flush` now receives the damage: `nil` =
  canvas unchanged, else `{top, bot}` 0-based inclusive new-frame rows
  (`bot < top` = pure deletion). The diff is canvas-vs-canvas, never against the
  buffer — the buffer legitimately diverges where mirrors wrote.
- [x] H2. Subwin damage plumbing: `sync(damage)` (false = pure scroll / no-op
  flush; table = spliced rows; nil = unknown → assume all, mount.lua maps
  on_flush nil → false) forces re-extraction only for widgets whose content box
  the splice reached. Consequence of no wholesale repaint: whoever paints over
  the canvas must clean up after itself —
  - `mirror()` records `entry.mirrored`; `restore_box()` writes
    `host.canvas_lines` (new: retained painted canvas, the pre-mirror ground
    truth) back over a box;
  - destroy() restores the canvas under the old box (else stale mirror text
    lingers wherever the next flush's damage doesn't reach); sync destroys FIRST
    so a restore can't land on a survivor's fresh mirror;
  - a moved/resized box restores the OLD box before mirroring the new one
    (fixed-height shrink orphans rows with zero canvas damage).
- [x] H3. **Stale-mirror-on-unfocus bug** (user report: "the view of an
  unfocused subbuffer becomes empty until the next relayout that hits it"): a
  flush that damaged a FOCUSED widget's box blanked the canvas there, but
  reposition skips extraction while focused and the memo key never changed (no
  edits) — so leaving showed the blank until some later flush hit the box. Fix:
  a forced reposition on a focused entry invalidates `entry.extracted`; the
  WinLeave reposition then repairs the mirror. (Pre-damage-tracking this needed
  every flush to hit every box to self-heal; now it's spec'd: "a damaging flush
  while the widget is focused repairs the mirror on leave".)
- [x] H4. Specs: tests/inline/damage_spec.lua — no-change relayout writes
  nothing (changedtick + mark ids stable), one-row change splices exactly that
  row (buf_attach on_lines range + surviving mark ids), row-count change
  equivalent to full repaint, on_flush damage contract ("0:2"/"1:1"/nil),
  miss-flush leaves extraction untouched (tick delta == 1: only the splice
  wrote), damaging flush re-extracts over the splice, unmount restore, shrink
  restore, focused-damage repair-on-leave. Note: mark IDs restart after a
  namespace clear — id stability alone is a weak observable, the changedtick
  delta is the honest one. Adapted contract: bare persistent-extmark changes (no
  event, no changedtick) now reach the mirror on the NEXT extraction rather than
  on any flush; Diagnostic/ LspToken events still force via view_dirty.
- [x] H5. Benchmarks (the "was it worth it" gate), before → after:
  - micro (bench/run.lua, N=100 sections ~600 nodes, fixed 60-col): full
    re-commit 6.25 → 4.81ms; incremental 6.34 → 4.93ms; NEW scenario "scoped
    leaf update (state in child component)" — isolates the commit pipeline —
    5.12 → 4.13ms. Scroll tick unchanged 0.011ms.
  - docs homepage (160x45, syntax on): set_props 10.13 → 8.18ms avg; relayout
    9.44 → 7.47ms; scroll resync 0.06 → 0.03ms. The remaining ~7.5ms is pure
    engine (build_node + layout + paint + diff) — buffer writes and the
    ~1400/frame extmark clear+re-set churn are GONE, and unrelated flushes no
    longer touch widget mirrors/transcriptions at all (a clock tick now splices
    ~2 rows and skips every widget).
  - Verdict: worth it — ~20% on full-page frames, near-free no-change flushes,
    plus the H3 correctness fix falls out of the same mechanism. Next lever if
    wasm still hurts: subtree-scoped layout/paint memoization (the 7.5ms floor),
    NOT more write-side work.
- [x] H6. Nix: `packages.<sys>.default`/`.fibrous` (vimUtils.buildVimPlugin,
  doCheck off — the suite is the check; source tree stays a valid bare plugin
  dir for path consumers like fibrous-docs), apps `.#test` / `.#bench` /
  `.#example` (+ default = example) wrapping the Makefile entry points against
  the flake snapshot (committed/staged state — make targets remain the
  working-tree loop). README "Nix" section. `nix flake check` green.
- Suite: **231 passed, 0 failed** (222 + 9 damage specs); `nix flake check`
  green; docs 5/5 unaffected (bench-only consumer change none).

### Subtree-scoped layout/paint memoization (2026-07-04, night)

- [x] I1. **Dirtiness ticks** (fiber.lua): a global monotonic tick;
  `render_pass` (runtime.lua) stamps every fiber it renders
  (self_tick/tree_tick) and `Fiber.touch` bubbles the tick up the new
  `fiber.parent` chain from the pass's entry fiber, so "could this subtree have
  changed since flush N" is one integer compare. `host.set_state` stamps too (a
  state flip changes the resolved style without a render).
- [x] I2. **Node-tree reuse** (host.build_node): a fiber whose tree_tick ≤
  last-flush tick gets its previous node OBJECT back (`fiber._node` — no side
  maps), marked `_memo`. Every ancestor of a change is dirty by construction
  (touch), so fresh nodes always have fresh ancestors. Auto-sized raw_buffers
  recheck their LIVE line count (buffers change without renders). A fully clean
  tree at the same size short-circuits the whole flush (on_flush(nil), no build
  at all; raw_buffer counts rechecked).
- [x] I3. **Layout memo** (layout.compute): measure skips a `_memo` node under
  the same avail width (`_mw`); the position pass skips a `_memo` node assigned
  the same margin box — the four args packed into ONE number (`_lkey`, exact
  under 2^13) so the memo costs one hash slot + compare. Raw trees never carry
  `_memo`: pure-engine semantics unchanged.
- [x] I4. **Incremental paint** (render.update + Canvas persistence in host):
  while the canvas size holds, only changed subtrees repaint. Per node: reused +
  same rect → skip subtree; fresh but own-visual-intact (`_keep`) + same rect →
  descend; else repaint root. Roots are collected first, then blank-all (old ∪
  new rects, Canvas:blank_rect) → restore ancestor bgs (outermost first,
  clipped) → visit-all. Soundness leans on sibling rects never overlapping (no
  negative margins) and on Canvas:put/text keeping cell hl when passed nil.
  visit() records `node._prect`; update() returns dirty rows so the host PATCHES
  its retained line/span arrays (clean rows keep identity → the splice diff
  equates them by pointer). Size change / first paint → fresh canvas, full visit
  — every fallback is the old full path, and the memo_spec fresh-mount oracles
  pin byte-equality (lines + spans) through grow, shrink, text-shrink-in-place,
  bg-under-leaf and bordered-unmount steps.
- [x] I5. **Perf regression found & fixed while probing**: mount +40%, re-commit
  +30% after the naive Tier A — LuaJIT table rehashes (nodes crossed the 16-slot
  hash boundary; fibers the 8) plus a retained 700-entry map per flush. Fixes:
  `table.new` pre-sizing (fiber 16, node 16), fiber.\_node instead of maps,
  \_lkey packing. gc-off probes: mount 6.14 → 6.42ms (+4%), full re-commit 4.42
  → 5.35 (+0.9ms — the honest price of the bookkeeping, paid only on
  everything-dirty frames).
- [x] I6. **BUG (major, from the damage-tracking round): mount.lua's on_flush
  wrapper `damage == nil and false or damage` can never yield false** — Lua's
  `and false or` trap. Clean flushes passed nil → subwin sync treated it as
  "unknown, force everything" → EVERY widget re-extracted (mirror + transcribe,
  ~4.5ms on the homepage) on every clean frame, silently eating most of that
  round's relayout win. Found via jit.p profile of a clean relayout
  (subwin.mark/mirror dominating a frame that painted nothing). Fixed with an
  explicit if; regression spec "a no-change relayout through the mount leaves
  widgets fully alone" (host changedtick must not move at all).
- [x] I7. Benchmarks (before = start of 2026-07-04 evening, after = now):
  - micro (N=100, ~600 nodes): **scoped leaf update 5.12 → 0.103ms** (50x); full
    re-commit 4.81 → 5.24 (+9%, everything-dirty bookkeeping); mount ~7
    (noise-level change); scroll tick 0.011 unchanged.
  - docs homepage (160x45, syntax on): **relayout 9.44 → 0.04ms**; **set_props
    10.13 → ~3ms avg**; scroll resync 0.03; hover 0.01.
  - The clock-tick shape (scoped update, fixed-width text) is the 0.1ms path:
    build/layout/paint touch only the clock's subtree, the splice writes ~1 row,
    no widget is re-extracted.
- Contract note (from I2): theme.styles changes don't reach memoized nodes — a
  theme swap needs a full re-render (set_props), same as before in practice
  since themes are session-static.
- Suite: **241 passed, 0 failed** (237 + 3 paint oracles + 1 wrapper regression
  spec); docs 5/5; `nix flake check` green.

### Layout min/max clamps + docs responsive playground (2026-07-04, late night)

User-reported docs issues: separators not full length; the component preview
shrinking to nothing on narrow (mobile) viewports.

- [x] J1. **Layout feature: `min_width` / `max_width` / `min_height` /
  `max_height` props** (border-box, like width/height; min wins, CSS-style).
  Three attachment points in layout.lua, all TDD'd (6 specs):
  - measure: final size clamped; `max_width` also tightens the measuring
    constraint so wrapping text reflows under it;
  - grow distribution: flexbox-style freeze loop — ideal weighted shares,
    violators clamp to their bound and freeze (their space leaves the pool),
    re-share; when space is short only min floors freeze first, so a capped
    sibling can still absorb the re-share (the naive clamp-everything would
    overflow);
  - cross-axis stretch: capped by max (min needs nothing — measure floors it).
  Bench: pure layout+paint 1.63 → ~1.70ms (+4%) on the everything-fresh path
  only; memoized frames skip layout entirely. Suite 247/0.
- [x] J2. **Docs: full-width separators** — the hardcoded `string.rep("─", 100)`
  label replaced by an empty col with only a top border: stretches to the page
  width (default cross-axis align), border chars draw the rule at any size.
- [x] J3. **Docs: responsive editor/preview row** — editor col
  `grow = 3, max_width = 80` (raw_buffer drops its fixed width and stretches),
  preview `grow = 1, min_width = 30`: on wide screens identical to before
  (editor 80, preview takes the rest); when narrow the editor is what shrinks.
  Both fixes red-green'd at the docs level (2 home_spec specs, verified red
  against the old site code via stash).
- Parked: stacking editor above preview on very narrow viewports (below ~36
  content cols the editor gets crushed; vertical stacking needs either a
  width-aware component re-render on resize or a layout-level wrap).

### Bundled web font + flat-style-prop removal (2026-07-05, small hours)

- [x] K1. **Bundled fonts for the wasm site** (user: JuliaMono, appearance must
  not depend on system fonts; flake-configurable). `mkNvimWasmWeb` grew
  `font.faces = [ { file, weight?, style? } ]`: faces copy into the webroot's
  `fonts/` and land in config.json; `web/main.js` FontFace-loads them BEFORE
  the renderer exists (cell metrics come from measureText — measuring against
  a fallback font would bake the wrong cell size into the session). A failed
  face falls back to the monospace stack. fibrous-docs sets JuliaMono px 17:
  raw TTFs are ~3.3 MB PER FACE, so a `webfont` derivation pyftsubsets each
  face (Latin, punctuation, arrows, math, box drawing/blocks/shapes,
  powerline) into woff2 — Regular+Bold+Italic total ~280 KB (verified: 1073
  glyphs/face, all site codepoints present). Swap `pkgs.julia-mono` for e.g.
  iosevka-bin in the docs flake to change the face.
- [x] K2. **Flat style props REMOVED** (user: "no users yet — just rip it
  out", upgrading the planned deprecation sweep). props.style is now the one
  styling vocabulary: `hl` = fill, `text_hl` = foreground, `border_hl`,
  border/padding/margin, `_hover`/`_focus`. The removed flat props (`hl`,
  `text_hl`, `bg`, `border`, `padding`, `margin`, `hover_hl`) ERROR loudly in
  style.normalize rather than silently doing nothing — component `hl` used to
  mean FOREGROUND while node/style `hl` meant FILL, and a silently-ignored
  leftover would be that trap again. components.lua no longer remaps anything
  (node_props is a plain copy). Raw layout trees are untouched: box.resolve
  still reads border/padding/margin off props (the engine's input format, not
  the component API), and render.lua still reads raw-tree props.hl/text_hl.
  - TDD: removal-error specs in style_spec + components_spec (originally
    written red as warn-once-shim specs; the user then chose removal);
    flat-sugar specs rewritten in style-table form.
  - Migrated: every host-path spec (the error made stragglers test failures —
    34 red → 247/0 green), bench/run.lua, all examples/, fibrous-docs webapp
    modules + the playground demo code strings + the "boxes" demo prose (the
    demos now TEACH the style vocabulary). Docs suite 7/7; homepage bench
    unchanged (relayout 0.05ms — memo intact).

### ui.animation component (2026-07-05)

- [x] L1. **`ui.animation`** (user-proposed API, kept as designed):
  `{ duration, value = fun(progress): string|Span[], fps? = 30, play? }`.
  progress lives in [0, 1) — elapsed time modulo duration, an implicit loop
  (bounce = a triangle wave inside value). Design points:
  - Component, not hook: every frame is a subtree-scoped leaf update — the
    memoized fast path (~0.1ms native), instead of re-rendering the consumer.
  - Frame 0 renders synchronously at mount (deterministic, no timer needed).
  - The uv timer calls value() each tick but commits ONLY when the returned
    spans differ (vim.deep_equal) — buffer writes scale with visible motion,
    not fps; a dot sitting between cell boundaries costs nothing.
  - The latest value closure lives in a use_ref, so inline closures don't
    re-arm the timer; deps (duration, fps normalized, play) do re-arm it.
  - Cleanup stops+closes the timer with a `stopped` guard (a scheduled fire
    can be in flight at unmount); value() errors inside the timer stop it and
    vim.notify once instead of spamming at 30fps (mount-time errors propagate
    normally, so error boundaries catch them).
  - TDD: tests/inline/animation_spec.lua, 7 specs (sync frame 0, advance +
    loop wrap, same-value ticks commit nothing via changedtick, unmount stops
    the timer, play = false freezes, style passthrough, arg validation).
    Suite 254/0.
- [x] L2. Docs playground section "Animations": the bouncing-dot bar
  (duration 1.3s triangle wave) + a slow fps=4 percentage readout; prose
  explains the frame-diff + scoped-commit economics. home_spec TITLES updated;
  docs suite 7/7.
- [x] L3. Bench scenario "animation": async by nature, so instead of ms/op it
  measures os.clock() CPU over vim.wait(1000) with ONE live animation in the
  N=100 page, against an idle-loop baseline. Native numbers: idle loop ~0.5
  ms CPU/s; bouncing dot at 30fps ~21 ms CPU/s at 29 commits/s (~0.7 ms per
  committed frame — span flatten + run attribution + scoped commit + timer
  dispatch, vs 0.12 ms for the bare label-text scoped update); static frame
  ~2.5 ms CPU/s at 0 commits — the diff-skip saves ~18 ms/s, leaving only
  30×(value() + deep_equal + dispatch).

### Transcript-scale perf: render bailout + paint descend + canvas growth (2026-07-04, late night)

Driven by remote-clanker.nvim (the ACP client rewrite in `~/src/remote-clanker.nvim`,
whose transcript is ONE long col of per-entry components): before this round,
ANY entries mutation at N=1000 entries cost ~50ms — the reconciler re-rendered
all N children (no bailout), which stamped every fiber dirty and defeated all
the I1–I4 memo tiers; and in scroll mode every append changed the canvas
height, discarding the canvas for a full fresh paint. `make bench-transcript`
(bench/transcript.lua, NEW) pins the workload: mount / append / stream-tick /
same-size mid-replace over memo'd entry components.

- [x] M1. **Reconciler render bailout** (reconciler.lua, VNode `memo = true`):
  React.memo semantics, per call site. On positional reuse with the same comp,
  a memo'd FUNCTION component whose props are SHALLOW-equal to the fiber's
  current props skips render_fiber entirely — subtree untouched, ticks
  untouched, so host build memo (fiber._node) holds through the parent's
  re-render. Function components only: a bailed fiber keeps stale
  children_specs, safe solely because function fibers re-derive children from
  `rendered` (a host fiber would freeze its children — pinned by the "ignored
  on host primitives" spec). Own set_state is unaffected (schedules the fiber
  itself). Composes with the store discipline: reassign arrays, keep unchanged
  entry OBJECTS reference-stable, build fresh `{ entry = e }` props per render
  (shallow compare absorbs the fresh table). 9 specs in
  tests/reactive/memo_bailout_spec.lua (skip/effect-skip, value change, key
  removal, non-memo default, own-state, subtree skip, tick preservation, type
  switch, host guard).
- [x] M2. **Container chrome-descend** (render.update + host.build_node
  `_prev`): a container rebuilt BECAUSE IT RE-RENDERED (the list committing a
  new children array) used to become a repaint root — full blank + repaint of
  every entry, O(N) cells, even when N-1 children were `_memo` at their old
  rects. Now build stashes the previous incarnation on rebuilt containers
  (`_prev`, consumed on every paint path so old nodes never chain), and the
  walk descends when the rect is unchanged and `chrome_equal`: same bg, same
  border (sides/chars/corners/hl/title), same border_hl, and NO CHILD LOST —
  removals still repaint wholesale because only the parent's blanket blank
  cleans a vanished child's cells (pinned by the "lost trailing child" spec).
- [x] M3. **Canvas growth** (Canvas:grow + host + growth-descend): scroll-mode
  frames that only get TALLER grow the canvas in place (blank rows appended)
  instead of discarding it; host patches retained arrays with update()'s dirty
  rows plus the virgin grown rows. A CHROME-LESS container whose rect grew
  strictly downward (same x/y/w) descends — old cells right, new area virgin;
  any chrome rejects (bottom border/bg stretch — pinned by the bordered-growth
  spec). Width change or shrink → full fresh paint as before. Host-level
  guards: damage_spec "appending splices only the appended rows" (one write,
  mark ids above survive), memo_spec fresh-mount oracle through two grows.
- [x] M4. **Numbers** (native, width 100, ~3.5 lines/entry): N=1000 —
  append 53.9 → 1.0ms, stream tick 47.1 → 0.68ms, same-size mid-replace
  48.9 → 0.62ms; mount 46ms (one-time). N=4000 — all ops ~10-12ms: the
  remainder is flat O(N) walks with tiny constants (spec building in the list
  component ~12%, build/layout ~30%, reconcile ~6%, splice scan ~9% — jit.p,
  no hotspot). Verdict: fine under the transcript's 40ms-debounce coalescing;
  if truly monstrous sessions ever hurt, the escape hatch is app-level
  windowing (mount last K entries + "older messages" expander), no framework
  support needed. Suite 285/0, docs 7/7.

- [x] text_input app hooks for chat prompts (2026-07-04, driven by clanker's
  R5 panel): `clear_on_submit = true` empties the buffer after on_submit (the
  buffer is the post-seed source of truth, so only subwin can clear it);
  `on_create(bufnr)` fires once at subwin creation so apps can wire
  buffer-local options/maps (completefunc for slash commands, steer keymaps).
  2 specs in input_spec; suite 287/0.

- [x] **Multi-container: `ui.container` (2026-07-04).** One fiber tree, N
  buffers — the reconciler is untouched; the boundary is a HOST-layer concept.
  A container is a subwindow leaf in its parent's layout tree (border/bg paint
  inline, float covers the content box, like text_input), whose children build
  into a separate layout tree (`node.inner`) flushed into the container's own
  buffer. Pieces:
  - host.lua: per-buffer retained state (prev lines/spans, persistent canvas,
    tree, subwins, pending damage) became FlushTarget records keyed by the
    boundary fiber (root keyed by the host); flush processes targets
    parent-first so a child's constraint is its fresh boundary rect. Damage
    accumulates per target ("all"/"none"/range) and is consumed by the manager
    via `host.take_damage`; `drop_target` retires a dead boundary's buffer.
    Memoization crosses the boundary: a memo-hit boundary marks its inner root
    `_memo` (layout + paint skip wholesale), a rebuilt one hands the inner root
    the same `_keep`/`_old_rect`/`_prev` bookkeeping as any container node.
  - layout.lua: a boundary leaf measures its inner tree under the same
    constraint — auto-size is CORRECT (not raw_buffer's live-line-count hack);
    explicit height/grow = viewport, props.mode "scroll" (default, buffer
    grows + float scrolls natively) | "fixed" (content laid out at exactly the
    viewport height, grow/justify fill it).
  - subwin.lua: manager parameterized by target (attach opts { target, mouse,
    zindex }); a container entry recursively attaches a nested manager +
    interact to ITS float (zindex +10/level), syncs it with the child target's
    damage, and tears it down innermost-first (focus walked out level by
    level). Containers are policy "always" (a mirror can't carry nested
    floats); page motions stay native inside them (they scroll); a hidden
    (fully occluded) container hides everything under it.
  - interact.lua: parameterized by target (hit-map on the target's tree, maps
    on its buffer) — hover/activate/insert-entry work identically one level
    down. Focus stays "the window the vim cursor is in": enter/exit hop one
    boundary at a time through the existing enter_at/edge-exit machinery.
  - `on_create(bufnr, winid)` fires once at container creation (like
    text_input's, plus the float) — the app hook for buffer-local keymaps and
    window work (follow-scroll, focusing); drove clanker's panel rework.
  - Perf: VIEWPORT containers (height/grow) skip the inner measure — its size
    doesn't depend on content, and measuring at the measure-pass width inside
    a row (≠ final laid-out width) flip-flopped every inner node's `_mw` and
    re-wrapped the whole inner tree twice per flush (clanker panel bench,
    N=500: 10.7 → 3.1ms/stream-tick; the rest is the flat O(N) walks M4
    documented). KNOWN CAVEAT: an AUTO container inside a row still measures
    at the pass width and relayouts at the final one — same double-measure
    pathology; use height/grow (or an explicit width) for containers in rows.
  - tests/inline/container_spec.lua (11): own-buffer render + root mirror,
    auto-size, viewport + fixed mode, per-target damage (unrelated updates
    leave the container buffer's changedtick alone), nested input end-to-end,
    <CR>-hop in / edge-hop out across two levels, on_create,
    container-in-container, conditional removal (buffer retired, boundary
    restored), scrolled reposition of nested floats, teardown. Suite 298/0.

- [x] **Mount shell fixes from panel dogfooding (2026-07-04, user bug
  reports).** Two "the background is reachable" holes in the split/window
  mounts, both fixed in mount.lua:
  - **Pane focus forwarding:** `<C-w>`-navigation only sees layout windows, so
    `<C-w>l` into the app landed on the blank scratch PANE behind the root
    float. A WinEnter autocmd forwards any focus the pane receives into the
    float (guarded on float validity, so teardown races are no-ops).
  - **Fixed-mode view pinning:** nvim scrolls any window until its last line
    hits the top even when the buffer fits, so the fixed-mode root canvas
    (which IS the viewport) could be scrolled into blank space. `pin_view`
    snaps topline/leftcol back on WinScrolled, wired BEFORE subwin.attach so
    the manager's resync (definition order) sees the restored view — no float
    swim. Scroll-mode mounts are untouched (the window is a real viewport).
    GOTCHA (second user report, "wheel scroll can stick"): the restore must be
    DEFERRED (vim.schedule), not inline — a view change made inside the
    WinScrolled autocmd is invisible to nvim's per-window scroll checkpoint,
    so an inline restore leaves the checkpoint at the scrolled topline and the
    next wheel notch landing on that same topline fires NO event (pin never
    runs, root stuck scrolled). Deferred, the restore is itself an observed
    scroll and the checkpoint tracks. Reproduced + verified against a live
    `--headless --listen` demo (real WinScrolled cadence, nvim_input_mouse
    wheel bursts): root pinned through 20 notches, transcript container still
    scrolls natively.
  - Also pinned by spec while chasing a clanker cursor-jump report: a splice
    under a window cursor does NOT move it (fold-toggle pattern spec in
    container_spec — fibrous was already correct; the jump was clanker's
    follow-mode autoscroll firing on visibility-only store mutations).
  - Specs: mount_spec +2 (pane forwarding; fixed pins/scroll survives — NB
    WinScrolled never fires in headless -l, the spec delivers it via
    nvim_exec_autocmds), container_spec +1. Suite 301/0.

- [x] **Layout: an explicit `width` pins the measuring constraint (2026-07-04,
  found reworking clanker's sidebar).** measure() only let `max_width` tighten
  the constraint — a fixed-width col late in a ROW measured its subtree at the
  row's remaining space, and since the position pass only re-wraps
  col-STRETCHED text, a wrapping paragraph inside a nested row kept its
  over-wide measure and painted clipped at the canvas edge (sidebar task rows:
  icon + paragraph). Now `props.width` REPLACES the incoming constraint
  (border-box, margins added back), so the subtree measures and wraps at the
  width the node actually gets — this also makes the wrap memo stable inside
  rows and makes the documented "explicit width" workaround for the
  AUTO-container-in-row caveat actually work. Spec: "an explicit width pins
  the measuring constraint" (the nested-row shape; the col-stretch shape was
  already green). Suite 302/0.

- [x] **Tab navigation (2026-07-05, user request).** `<Tab>`/`<S-Tab>`
  (NORMAL mode only, buffer-local on each flush target) cycle the cursor
  through the target's interactive nodes — role carriers plus text_input
  subwindow leaves — in DOCUMENT order (pre-order: a column's stops finish
  before the next column starts), wrapping at the ends. Landing is just a
  cursor move: hover repaints via the existing update(), activation stays on
  <CR>/<Space>, and subwindows are still entered explicitly, never by
  traversal (the cursor lands ON the input; i/<CR> enters). From an inert
  cell, forward goes to the first stop spatially past the cursor in reading
  order. Cycling is per flush target by construction (a container leaf's
  children live in another target's tree; the container's own interact layer
  — same code — cycles them). NB `<Tab>` shadows `<C-i>` jumplist-forward
  inside canvas buffers, the usual UI-buffer trade. Specs: interact_spec +5.
  Suite 307/0.
- [x] **Stacking policy + modal chrome (2026-07-05, user request).** Every
  float used to sit at/above nvim's default (roots 50, subwin levels 60 +10
  per nesting), so a pane-anchored app's containers COVERED any genuine
  float — clanker's session modal rendered behind the transcript. New
  policy: pane-anchored mounts (window/split) are page furniture, root
  zindex 10 and +1 per subwindow level, keeping the whole stack below 50;
  float mounts root at 50 (level with other plugins' popups), +1 per level;
  `opts.zindex` overrides the root everywhere and levels always derive
  root+1. Plus two mount.floating opts for modal-shaped apps:
  - `border` — passed through to the root float (persists across relayout).
  - `backdrop` — Snacks-style editor dim: ONE full-screen non-focusable
    scratch float (`FibrousBackdrop` default hl, bg=#000000 + winblend;
    `backdrop = <n>` sets the blend, true = 60; needs termguicolors to
    blend rather than block). Lifecycle rides the mount's: resized in
    sync(), closed as an attachment teardown — no autocmds of its own.
    Deliberately NOT a "Modal" widget: modal remains an app-level pattern;
    fibrous provides the primitives.
  Specs: mount_spec +4 (stacking, zindex override, backdrop lifecycle,
  border persistence); style_state_spec's subwin finder updated (60 → 51).
  Suite 311/0.
  FOLLOW-UP (same day, user bug report — "panel blanked out under the
  modal"): diagnosed against the composed screen (demo in a :terminal of a
  headless host): nvim's compositor does NOT blend floats through a
  winblend float — anything below it is hidden and the blend samples the
  BASE GRID only. Two candidate placements: (a) backdrop UNDER the
  pane-anchored stacks (z=5) — normal windows dim, page furniture stays
  visible but undimmed; (b) backdrop one z-level below the root (49) —
  normal windows dim, page furniture is OBSCURED outright. Shipped (a)
  first; USER DECISION reverted to (b): a modal should obscure the panel,
  not float over a bright one. So: backdrop z = root-1, floats beneath it
  disappear by design, documented on the opt. Also learned:
  `nvim_win_set_config` zindex changes don't re-sort the compositor's draw
  order for an existing float (a fresh float at the same z behaves
  correctly) — diagnose stacking with fresh floats only.

- [x] **Mark gravity inversion under box writes (2026-07-05, user bug:
  "widget highlights sometimes disappear until the next update while
  resizing the OS window").** Root cause was NOT the splice — its set_lines
  relocation shifts tail marks cleanly (verified by instrumenting
  set_lines/set_text/clear_namespace inside the live demo and snapshotting
  marks after every edit). The killer is mirror()/restore_box(): they
  rewrite moved widget boxes via nvim_buf_set_text, and a replacement that
  covers a canvas mark's EXACT extent inverts it through gravity — the
  start (right gravity) lands at the edit's end, the end (no gravity) at
  its start ⇒ `start=210,end=0` spans that render nothing until the next
  splice repaints the row. Resizes trigger it constantly because boxes
  move every relayout. Fix: `repaint_row_marks(y0,y1)` in subwin.lua —
  after any mirror/restore write, clear host.ns on the touched rows and
  re-add from `target.prev_hl_rows` (ground truth), `strict=false` since a
  mirrored row's byte length may run short of the canvas line. Spec:
  subwin_spec "box writes never corrupt canvas highlight marks" (label and
  input swap rows; restore_box rewrites the label's row). Suite 312/0;
  clanker bench unchanged (stream tick 0.83ms @ N=1000). Diagnosis
  technique worth keeping: run the demo inside a :terminal of a headless
  host (real PTY resizes), monkeypatch the buffer-edit API to log
  edit→markset transitions.

- [x] **Byte-divergent mark misplacement in `repaint_row_marks` (2026-07-05,
  follow-up to the gravity fix; user bug: "incorrect extmarks especially
  when resizing horizontally").** The gravity fix re-placed marks at their
  CANVAS byte offsets (`prev_hl_rows.start_col/end_col`), but a mirror write
  can change the row's byte layout — multibyte widget content (box-drawing
  markdown, `─╭╮`) over single-byte canvas cells, or vice versa. So a mark
  BESIDE a mirrored box (e.g. a sidebar checkbox sharing rows with the
  transcript container box) lands at a stale byte offset and paints the
  wrong cells or vanishes. Horizontal resize is the trigger: it moves the
  container box, so restore_box/mirror rewrite rows the sidebar marks live
  on. Fix: when the current line diverges from the canvas ground truth,
  translate each span's byte cols THROUGH DISPLAY CELLS onto the actual line
  (`width.cell_to_byte(cur_line, width.str(canvas:sub(1, col)))`). Spec:
  subwin_spec "box writes keep marks beside the box cell-faithful
  (byte-divergent mirror)" — a 10-cell input swapped to 3-cell/9-byte
  multibyte content, TAG label to its right stays at cell 10. Verified live
  with a CELL-AWARE invariant (marks must sit on UTF-8 boundaries AND cover
  the same display cells as the canvas span) — held through horizontal
  resize storms that the old raw-byte invariant reported "clean" for
  (because the buggy code placed marks at the very canvas offsets that check
  compared against). Suite 314/0; bench unchanged (append 1.9ms, toggle
  14.1ms @ N=1000 — the extra per-row get_lines is free).

- [x] **Stranded `_focus` accent on startup (2026-07-05, user bug: "the
  prompt shows focused (blue border) when the panel is created even though
  the cursor isn't in it; focusing then unfocusing clears it").** subwin.lua
  drove `_focus` off WinEnter/WinLeave on the float's buffer, but focus can
  leave a float WITHOUT a WinLeave: nvim's own startup re-enters the first
  window AFTER `-u init` sourcing with autocmds suppressed (also any
  `:noautocmd wincmd`), so a focus grab during init strands the style ON.
  Fix: a manager-level WinEnter (not buffer-scoped) tracks the currently
  focused entry and reconciles — the first genuine window entry anywhere
  clears a stale accent. Spec: style_state_spec "a stale focus accent heals
  once any window is entered normally" (focus a float, yank focus back under
  `eventignore=all`, assert the accent survives, then `:new` clears it). The
  clanker side ALSO defers its own focus grab past VimEnter (panel_spec
  "opened during startup, the prompt is genuinely focused after VimEnter",
  driving a real child nvim). Suite 314/0.

- [x] **One-keystroke activation across a container boundary (2026-07-05,
  user request).** Before: pressing a button inside a container while focus
  was on the parent took TWO `<CR>`s — the root's activate only offered the
  cell to `subwins.enter_at`, which FOCUSED the container float and stopped;
  the button press needed a second `<CR>` on the container's own layer.
  Reason: each flush target (root, every container) has its own
  `interact.attach` layer driven by ITS window's cursor, and the boundary was
  entered explicitly (one level per `<CR>`). Fix: new `subwins.activate_at`
  (subwin.lua) = `enter_at` (focus + land the cursor via the mirror_map
  translation) THEN, if the entry is a container, delegate to its
  `child_interact.activate(true)`. interact.lua's `<CR>`/click path calls
  `activate_at` instead of `enter_at` (insert keys keep plain `enter_at`), and
  the interact handle now exposes `activate` so a parent can delegate in.
  Recurses through nesting (a container's activate calls its own
  `activate_at`), so a button any depth down is one `<CR>`, and it does
  press-AND-focus (focus stays in the container, per the user's ask). Over a
  non-interactive cell it just focuses (identical to the old first `<CR>`), so
  the "focus hops" stepping for plain labels is unchanged. Spec:
  container_spec "<CR> over a button inside a container presses it AND focuses
  the container (one press)". Suite 315/0; clanker 164/164 (the transcript's
  tool-call headers are buttons in a container — now one `<CR>` from the root
  toggles them; verified live). Keyboard `<Tab>` traversal stays island-scoped
  by design.

- [x] **Hover across the container boundary (2026-07-05, user request,
  follow-up to the activation change).** Continuation of the same idea for the
  continuous case: gliding the parent's cursor over a button in an UNFOCUSED
  container now highlights it, without moving focus. Design (user's, chosen
  over a cursor-independent `hover_at` paint): since each surface's hover reads
  ITS OWN window's cursor and Neovim cursors are per-window, drive off the
  parent's live cursor and NUDGE the (unfocused) container's own cursor to the
  translated, always-visible cell (shared `translate()`, no scroll — same
  landing `enter()` uses), then run the container's existing interaction so it
  paints on the float the user sees. Verified `nvim_win_set_cursor` on a
  non-current window and `nvim_win_call(winsaveview/winrestview)` do NOT
  disturb the parent's visual selection / mode / curwin (the user's worry) —
  so no `win_call` needed anyway (the translated line is always visible, so
  set_cursor never scrolls). Wiring: `subwins.hover_at(row,x)` finds the
  container under the cell, translates, nudges its cursor, calls its
  `child_interact.update(true)`; recurses for nesting; tracks the hovered
  entry to `clear_hover()` on leave. interact.lua's `update(propagate)` gained
  a LIVENESS gate — hover only paints where the cursor is the live pointer
  (this window current, or parent-driven); an unfocused, un-pointed container's
  update() (which still runs every flush via sync) now CLEARS instead of
  painting a phantom hover at its idle cursor (the bug that surfaced: a fresh
  mount showed a stray button hover). `clear_hover` guards its relayout with
  `syncing` against flush re-entry. Spec: container_spec "hover reaches into an
  UNFOCUSED container… focus stays on the root" (hover appears on the container
  buf, focus unchanged, clears on leave). Suite 316/0; clanker 164/164, bench
  unchanged (append 1.16ms, toggle 10.7ms @ N=1000); verified live (root cursor
  over the transcript's tool header highlights it, focus stays on the root,
  clears on leave). NB button hover is the themed `FibrousButtonHover` fill
  (hl-tier overlay), not `FibrousHover`.

- [x] **Hover/activation clamped onto the last line from a container's dead
  space (2026-07-05, user bug).** When a container box is taller than its
  content, the blank padding rows below the last line had no `mirror_map`
  entry, so `translate()`'s fallback CLAMPED them (`math.min(…, count)`) onto
  the last content line — a parent cursor over that dead space hovered, and
  `<CR>` activated, the last line's button. Fix: `translate` now returns a
  third `content` boolean (false for box rows past the buffer's end; lnum still
  clamps so a focus can land). `hover_at` treats dead space as no target
  (clears, no paint); `activate_at` still focuses the container but skips the
  press when `content` is false. Spec: container_spec "dead space past a
  container's content never hovers or activates its last line" (control: the
  real button row still hovers). Suite 317/0; clanker 164/164.

### remote-clanker.nvim (ACP client on fibrous) — design decisions (2026-07-04)

- Transcript = per-entry COMPONENTS (tool call, thought, prompt, output…), not
  a raw managed buffer — ADR 0008's bug class (stale lines, fold loss, scroll
  races) is what the pure projection precludes; M1–M3 above make it O(change).
- No virtual scrolling: buffer + scroll-mode viewport already virtualize the
  display; CPU is bounded by the memo tiers.
- Store: plain Lua + subscriber list (NOT nui-components signals), reassign
  references on mutation; keep agentic's permission FIFO queue pattern.
- Copy `acp/` + `acp_bridge` wholesale (store-agnostic already); prompt =
  text_input subwin; panel dock = mount.split(); tool-call fold = conditional
  render on store `expanded`.
- Markdown/diff highlighting: per-entry "parse once on stream-settle, cache
  spans" (detached string parser) — strictly better than agentic's
  viewport-throttled repaint; wants to become a fibrous component eventually.
