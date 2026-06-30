# Design Document: Fullscreen Interactive Neovim WASM Playground

## 1. Executive Summary

The goal of this project is to build an interactive, high-impact marketing and
documentation homepage for `fibrous`—a React-like framework built completely
in Lua for the Neovim ecosystem.

To demonstrate the capabilities of the framework without friction, the homepage
will present a standalone, fullscreen Neovim terminal instance running entirely
client-side inside the user's web browser via WebAssembly (WASM). The user
interface of this website will be constructed natively using the `fibrous`
Lua components running inside that sandboxed Neovim instance.

______________________________________________________________________

## 2. System Architecture

The ecosystem is split into three strictly decoupled, independent tiers to
ensure component reusability, maintainable codebases, and a highly optimized
build pipeline.

```
+-----------------------------------+
|       1. fibrous (Lua)         |  <-- Pure plugin logic
+-----------------------------------+
                  |
                  v (Pulled at build time)
+-----------------------------------+
|     3. fibrous-docs (Web)      |  <-- Injects Lua via static bundle
+-----------------------------------+
                  ^
                  | (Consumes binary artifacts)
+-----------------------------------+
|     2. nvim-wasm-core (C/WASM)    |  <-- Agnostic Neovim engine
+-----------------------------------+

```

### 2.1. Tier 1: Core Library (`fibrous`)

- **Responsibility:** The underlying framework providing reconciliation, virtual
  DOM/tree mappings, state management hooks (`useState`), and side effects
  within Neovim.
- **Environment:** Pure Lua. It remains strictly decoupled from the web layer
  and contains no logic pertaining to WASM, browsers, or web toolchains.
- **Distribution:** Installed by end-users via standard Neovim package managers
  (e.g., `lazy.nvim`).

### 2.2. Tier 2: The WebAssembly Core Engine (`nvim-wasm-core`)

- **Responsibility:** Compiles the upstream Neovim source code (written in C and
  Lua) into raw WebAssembly binaries.
- **Characteristics:** Completely agnostic of `fibrous`. It mocks the
  operating system filesystem in memory and patches platform-specific
  abstractions (like `libuv` async I/O loops) to execute smoothly inside a
  browser sandbox.
- **Output Artifacts:** `nvim.wasm` (compiled executable binary) and `nvim.js`
  (Emscripten JavaScript glue code).

### 2.3. Tier 3: The Documentation Site (`fibrous-docs`)

- **Responsibility:** The customer-facing, single-page application orchestrating
  the layout, bootstrapping the web terminal, and injecting the framework
  dependencies.
- **Characteristics:** Intentionally minimalist. It rejects heavy static-site
  frameworks (e.g., Next.js, Astro) in favor of a raw single-page app containing
  an HTML5 canvas or terminal DOM container (using `xterm.js`).
- **State Management:** Employs a pre-compilation build step to serialize raw
  Lua modules directly into the client-side JavaScript layer, mitigating browser
  network waterfalls during initialization.

______________________________________________________________________

## 3. Data Flow & Compilation Lifecycle

### 3.1. Build-Time Phase (Deterministic Bundle Assembly)

Rather than executing a heavy compilation script or loading modules over the
network dynamically at runtime, a lightweight Node.js script converts the
filesystem layer into code assets during production compilation.

1. The build script scans the local path of the `fibrous` repository.
1. Every `.lua` source file is read and mapped into a single JSON dictionary
   (`LUA_VIRTUAL_FS`), where keys are the explicit target sandbox paths and
   values are strings of raw Lua code.
1. This dictionary is exported as a static JavaScript artifact
   (`lua_bundle.js`).

```javascript
// Generated inside public/lua_bundle.js
window.LUA_VIRTUAL_FS = {
  "/root/.config/nvim/lua/fibrous/init.lua": "...",
  "/root/.config/nvim/lua/fibrous/reconciler.lua": "..."
};

```

### 3.2. Runtime Bootstrap Phase (Client Initialization)

When an internet user visits the root domain, the browser initiates execution
asynchronously:

```
[Fetch index.html] -> [Load lua_bundle.js & nvim.js] -> [Mount Memory VFS] -> [Call main()]

```

1. **Asset Load:** The browser downloads `index.html`, `styles.css`,
   `lua_bundle.js`, and the core engine binaries.
1. **Virtual Filesystem Initialization:** Before the WebAssembly container
   starts, a JavaScript helper iterates through `window.LUA_VIRTUAL_FS` and
   interacts with Emscripten's Virtual File System API:

```javascript
for (const [path, content] of Object.entries(window.LUA_VIRTUAL_FS)) {
  const dir = path.substring(0, path.lastIndexOf('/'));
  Module.FS.mkdirTree(dir);
  Module.FS.writeFile(path, content);
}

```

3. **Execution:** The browser invokes `Module.callMain()`. Neovim boots,
   processes the newly mounted virtual configurations, and executes
   `require('fibrous')` locally in RAM with 0ms network latency.

______________________________________________________________________

## 4. Reproducible Environment Configuration (Nix Flakes)

The infrastructure utilizes Nix Flakes to achieve total reproducibility across
development machines and CI/CD pipelines, isolating Emscripten and Node
dependencies from host operating systems.

### 4.1. Core Engine Builder Flake (`nvim-wasm-core/flake.nix`)

Bypasses the restrictions of Nix's read-only store by establishing writeable
cache overrides required by Emscripten's system code generation.

```nix
{
  description = "Agnostic Neovim WebAssembly Build Pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ emscripten gnumake cmake ninja pkg-config nodejs ];
          shellHook = ''
            export EM_CACHE="$PWD/.em_cache"
            mkdir -p "$EM_CACHE"
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "nvim-wasm";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = with pkgs; [ emscripten cmake ninja pkg-config ];
          preBuild = "export EM_CACHE=$(mktemp -d);";
          buildPhase = "make wasm;";
          installPhase = "mkdir -p $out; cp nvim.wasm nvim.js $out/;";
        };
      });
}

```

### 4.2. Documentation Site Flake (`fibrous-docs/flake.nix`)

Automates the compilation of web bundles and packages raw outputs into a
production directory ready for static edge hosting.

```nix
{
  description = "Minimalist Fullscreen Neovim WASM Page Builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ nodejs_20 nodePackages.live-server ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "fibrous-homepage";
          version = "1.0.0";
          src = ./.;
          buildInputs = [ pkgs.nodejs_20 ];
          buildPhase = "node build.js;";
          installPhase = ''
            mkdir -p $out/public
            cp -r index.html styles.css app.js public/lua_bundle.js nvim-wasm.js nvim.wasm $out/public/
          '';
        };
      });
}

```

______________________________________________________________________

## 5. UI/UX Design & Edge Cases

### 5.1. User Interaction & Core Conceptual Demos

The fullscreen instance should leverage its environment to showcase typical
React utilities ported to terminal contexts:

- **Interactive Counters:** A multi-pane interface inside Neovim showcasing raw
  component source code on the left pane (`useState`), and a live rendering
  bounding-box button on the right pane responding to keyboard/mouse input
  clicks.
- **DevTools Reconciliation Inspectors:** A togglable overlay showing a live
  representation of the virtual DOM hierarchy, complete with flash highlights
  when nodes re-render on active updates.

### 5.2. Mobile Support & Pointer Abstractions

To ensure accessibility on mobile viewport browsers, the frontend implements a
translation engine mapping touch interactions directly into native Neovim input
sequences (relying on Neovim's standard `:set mouse=a` capabilities).

#### 5.2.1. Tap to Click Translation

The JavaScript engine intercepting DOM bounds maps screen coordinates relative
to the bounding client box to evaluate exact terminal grid targets.

```javascript
el.addEventListener('touchend', (e) => {
  const touch = e.changedTouches[0];
  
  // Convert absolute dimensions to terminal column/row boundaries
  const col = Math.floor(touch.clientX / CELL_WIDTH);
  const row = Math.floor(touch.clientY / CELL_HEIGHT);
  
  // Dispatch sequence down the WebAssembly RPC layer
  sendNvimMouseEvent({ button: 'left', action: 'press', row, col });
  sendNvimMouseEvent({ button: 'left', action: 'release', row, col });
});

```

#### 5.2.2. Gestural Scroll Map

Vertical swiping patterns (`touchmove`) evaluate linear deltas relative to
structural starting points. Crossing a localized delta threshold (e.g., 20px)
fires an isolated `<ScrollWheelUp>` or `<ScrollWheelDown>` packet sequence
straight into Neovim’s buffer interface, ensuring framework layouts scrolling
gracefully.

### 5.3. Critical Risk Mitigations

- **Initial Loading Overhead:** The base Neovim core package combined with
  standard Vim runtime initializers can grow to several megabytes. The
  application layer must feature an active DOM-based CSS rendering indicator to
  track installation loading progress, preventing bounce rates.
- **Keyboard Event Theft:** Browsers intentionally disable complete hijacking of
  core parameters (e.g., `Ctrl+W`, `Ctrl+N`). To prevent application lockups,
  navigation schemes must focus on Vim primitives like standard leader
  configurations, native arrow navigation, or buffer-local text hotkeys.
- **Viewport Shell Stabilization:** Mobile layers aggressively try to zoom
  layouts or surface contextual clip selections on click holds. The layout is
  isolated from host interference via strict viewport behaviors injected into
  CSS properties:

```css
.nvim-container {
  touch-action: none;          /* Inhibits pinch-to-zoom structures */
  user-select: none;           /* Disables browser contextual highlights */
  -webkit-user-select: none;
}

```
