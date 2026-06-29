{
  description = "nui-reactive — a React-like reactive UI framework for Neovim";

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
          pkgs.runCommandLocal "nui-reactive-tests"
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
