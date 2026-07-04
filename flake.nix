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
      packages = forAllSystems (pkgs: rec {
        default = fibrous;
        fibrous = pkgs.vimUtils.buildVimPlugin {
          pname = "fibrous";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          # the real gate is the test suite (`nix flake check`); the generic
          # require-check chokes on modules that need a running UI
          doCheck = false;
        };
      });

      # Runnable entry points, all against the flake's own snapshot of the
      # source (commit/stage changes to see them; use `make ...` against the
      # working tree during development):
      #   nix run .#test [-- tests/inline/host_spec.lua]   the suite / one spec
      #   nix run .#bench                                  inline host benchmarks (BENCH_N=…)
      #   nix run .#example [-- counter]                   examples browser in a clean nvim
      # `nix run .` (default) opens the examples browser.
      apps = forAllSystems (
        pkgs:
        let
          app = name: text: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name text;
                runtimeInputs = [ pkgs.neovim ];
              }
            );
          };
        in
        rec {
          default = example;
          test = app "fibrous-test" ''
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l tests/run.lua "$@"
          '';
          bench = app "fibrous-bench" ''
            cd ${self}
            exec nvim --headless -u NONE -i NONE -l bench/run.lua "$@"
          '';
          example = app "fibrous-example" ''
            if [ $# -gt 0 ]; then
              exec nvim --clean -u ${self}/examples/init.lua -c "Example $1"
            fi
            exec nvim --clean -u ${self}/examples/init.lua
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
