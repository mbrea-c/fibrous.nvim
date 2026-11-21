{
  description = "fibrous — a React-like reactive UI framework for Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # The plugin itself, packaged the standard nixpkgs way — drop it into
      # `programs.neovim.plugins` / a pack path / lazy's `dir`. The source tree
      # IS the plugin (lua/ at the root), so consumers that take a bare source
      # path (like fibrous-docs' mkNvimWasmWeb) can keep using the flake input
      # directly.
      packages = forAllSystems (
        pkgs:
        let
          nativeSource = pkgs.lib.cleanSource (self + /native/markdown);
          nativeMarkdown = pkgs.rustPlatform.buildRustPackage {
            pname = "fibrous-markdown-native";
            version = "0.1.0";
            src = nativeSource;
            cargoLock.lockFile = nativeSource + /Cargo.lock;
            # A LuaJIT module resolves the Lua symbols in its Neovim host.
            env.RUSTFLAGS = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin
              "-C link-arg=-undefined -C link-arg=dynamic_lookup";
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/lib"
              cp target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
              runHook postInstall
            '';
          };
          mkFibrous = pkgs.lib.makeOverridable (
            { withRustMarkdown ? false }:
            pkgs.vimUtils.buildVimPlugin {
              pname = "fibrous";
              version = self.shortRev or self.dirtyShortRev or "dev";
              src = self;
              doCheck = false;
              postInstall = pkgs.lib.optionalString withRustMarkdown ''
                mkdir -p "$out/lib"
                ln -s ${nativeMarkdown}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
                substituteInPlace "$out/lua/fibrous/_native_defaults.lua" --replace-fail "return false" "return true"
              '';
              passthru = {
                inherit withRustMarkdown;
                nativeMarkdown = if withRustMarkdown then nativeMarkdown else null;
              };
            }
          );
        in
        rec {
          default = fibrous;
          fibrous = mkFibrous { };
          fibrous-rust-markdown = fibrous.override { withRustMarkdown = true; };
          markdown-native = nativeMarkdown;
        }
      );

      # Runnable entry points — the CANONICAL, complete surface. Each wraps the
      # matching Makefile target (so the actual `nvim` invocation lives in ONE
      # place — `make …` and `nix run` can never drift), run against the flake's
      # own snapshot of the source (commit/stage changes to see them; `make …`
      # against the working tree during development):
      #   nix run .#test [-- tests/inline/host_spec.lua]   the suite / one spec
      #   nix run .#bench                                   inline host benchmarks (BENCH_N=…)
      #   nix run .#bench-transcript                        transcript-scale benchmarks
      #   nix run .#bench-markdown                          markdown parse/render/mount
      #   nix run .#bench-term                              terminal-draw bytes/frame (real pty)
      #   nix run .#bench-history -- --last 12 --reps 8     benches across git history → trend table
      #   nix run .#example [-- counter]                    examples browser in a clean nvim
      # `nix run .` (default) opens the examples browser.
      apps = forAllSystems (
        pkgs:
        let
          # A `make <target>` wrapper: neovim (the Makefile's `NVIM_BIN ?= nvim`
          # default resolves to it on PATH) + make, plus any extra tools a target
          # orchestrates with. Runs the target inside the flake's own snapshot.
          app = extraInputs: name: text: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name text;
                runtimeInputs = [
                  pkgs.neovim
                  pkgs.gnumake
                ]
                ++ extraInputs;
              }
            );
          };
        in
        rec {
          default = example;
          test = app [ ] "fibrous-test" ''
            cd ${self}
            if [ "$#" -gt 0 ]; then exec make test-file FILE="$1"; fi
            exec make test
          '';
          test-native = app [ pkgs.python3 ] "fibrous-test-native" ''
            export FIBROUS_TEST_NATIVE=${self.packages.${pkgs.stdenv.hostPlatform.system}.fibrous-rust-markdown}
            export FIBROUS_BENCH_MARKDOWN=${self.packages.${pkgs.stdenv.hostPlatform.system}.markdown-native}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
            cd ${self}
            exec make test-native
          '';
          bench-native-markdown = app [ pkgs.python3 ] "fibrous-bench-native-markdown" ''
            export FIBROUS_BENCH_MARKDOWN=${self.packages.${pkgs.stdenv.hostPlatform.system}.markdown-native}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
            export NVIM_BIN=${pkgs.lib.getExe pkgs.neovim}
            cd ${self}
            exec make bench-native-markdown ARGS="$*"
          '';
          bench-native-markdown-term = app [ pkgs.python3 ] "fibrous-bench-native-markdown-term" ''
            export FIBROUS_BENCH_MARKDOWN=${self.packages.${pkgs.stdenv.hostPlatform.system}.markdown-native}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
            export NVIM_BIN=${pkgs.lib.getExe pkgs.neovim}
            cd ${self}
            exec make bench-native-markdown-term ARGS="$*"
          '';
          bench-native-markdown-features = app [ pkgs.python3 ] "fibrous-bench-native-markdown-features" ''
            export FIBROUS_BENCH_MARKDOWN=${self.packages.${pkgs.stdenv.hostPlatform.system}.markdown-native}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
            export NVIM_BIN=${pkgs.lib.getExe pkgs.neovim}
            cd ${self}
            exec make bench-native-markdown-features ARGS="$*"
          '';
          bench = app [ ] "fibrous-bench" ''
            cd ${self}
            exec make bench
          '';
          bench-transcript = app [ ] "fibrous-bench-transcript" ''
            cd ${self}
            exec make bench-transcript
          '';
          bench-markdown = app [ ] "fibrous-bench-markdown" ''
            cd ${self}
            exec make bench-markdown
          '';
          bench-markdown-workload = app [ ] "fibrous-bench-markdown-workload" ''
            cd ${self}
            exec make bench-markdown-workload
          '';
          bench-markdown-maps = app [ ] "fibrous-bench-markdown-maps" ''
            cd ${self}
            exec make bench-markdown-maps
          '';
          bench-markdown-term = app [ ] "fibrous-bench-markdown-term" ''
            cd ${self}
            exec make bench-markdown-term
          '';
          bench-resize = app [ ] "fibrous-bench-resize" ''
            cd ${self}
            exec make bench-resize
          '';
          bench-resize-profile = app [ ] "fibrous-bench-resize-profile" ''
            cd ${self}
            exec make bench-resize-profile
          '';
          bench-resize-first = app [ ] "fibrous-bench-resize-first" ''
            cd ${self}
            exec make bench-resize-first
          '';
          bench-resize-term = app [ ] "fibrous-bench-resize-term" ''
            cd ${self}
            exec make bench-resize-term
          '';
          # Terminal-draw throughput: bytes nvim's TUI pushes at a real pty per
          # frame — the tmux+ssh cost (highlight repaints and escape overhead
          # included), one layer below the buffer-write cells/op figure. Spawns
          # child nvim TUIs, which isolate themselves via --clean.
          bench-term = app [ ] "fibrous-bench-term" ''
            cd ${self}
            exec make bench-term
          '';
          # Run the benches across git history and print a trend table. Reads the
          # repo at $PWD; NEVER writes it (clones to temp, worktrees there). The
          # bench harness is PINNED here (this flake's snapshot, ${self}), run
          # against each commit's library — so only lua/fibrous/ varies. Runtime
          # (this neovim) is constant too. e.g.
          #   nix run .#bench-history -- --last 12 --reps 8 --benches transcript
          bench-history = app [ pkgs.git pkgs.coreutils ] "fibrous-bench-history" ''
            export HARNESS_DIR="${self}"
            exec make bench-history ARGS="$*"
          '';
          example = app [ ] "fibrous-example" ''
            cd ${self}
            if [ "$#" -gt 0 ]; then exec make example EX="$1"; fi
            exec make example
          '';
        }
      );

      # `nix develop` drops you into a shell with the tools used for development:
      # neovim (the test host + target), make, the Lua language server (LuaCATS
      # type checking), and stylua (formatting).
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.gnumake
            pkgs.lua-language-server
            pkgs.stylua
          ];
        };
      });

      # `nix flake check` runs the full test suite in the build sandbox, in a
      # fully isolated headless Neovim (no user config, no plugins).
      checks = forAllSystems (pkgs: {
        package = pkgs.runCommandLocal "fibrous-package" { nativeBuildInputs = [ pkgs.neovim ]; } ''
          export HOME="$TMPDIR"
          export FIBROUS_PACKAGE=${self.packages.${pkgs.stdenv.hostPlatform.system}.default}
          EXPECT_NATIVE=0 nvim --headless -u NONE -i NONE -l ${self}/tests/native_package.lua
          touch "$out"
        '';
        native-markdown = pkgs.runCommandLocal "fibrous-native-markdown-tests"
          { nativeBuildInputs = [ pkgs.neovim pkgs.gnumake pkgs.python3 ]; } ''
          cp -r ${self}/. work && chmod -R +w work && cd work
          export HOME="$TMPDIR"
          export FIBROUS_PACKAGE=${self.packages.${pkgs.stdenv.hostPlatform.system}.fibrous-rust-markdown}
          EXPECT_NATIVE=1 nvim --headless -u NONE -i NONE -l tests/native_package.lua
          export FIBROUS_TEST_NATIVE="$FIBROUS_PACKAGE"
          export FIBROUS_BENCH_MARKDOWN=${self.packages.${pkgs.stdenv.hostPlatform.system}.markdown-native}/lib/libfibrous_markdown_native${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
          make test-native
          touch "$out"
        '';
        tests =
          pkgs.runCommandLocal "fibrous-tests"
            {
              nativeBuildInputs = [
                pkgs.neovim
                pkgs.gnumake
              ];
            }
            ''
              cp -r ${self}/. work && chmod -R +w work && cd work
              export HOME="$TMPDIR"
              make test
              touch "$out"
            '';
      });
    };
}
