{
  description = "dex";

  nixConfig = {
    substituters = [
      https://hydra.iohk.io
    ];
    trusted-public-keys = [
      hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=
    ];
    bash-prompt = "\\[\\033[1m\\][dev-dex]\\[\\033\[m\\]\\040\\w$\\040";
  };

  inputs = {
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.follows = "haskell-nix/flake-utils";
  };

  outputs = { self, nixpkgs, haskellNix, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" ] (system:
      let
        overlays = [
          haskellNix.overlay
          (final: prev: { llvm-config = prev.llvm_9; })
          (final: prev: {
            dexProject =
              final.haskell-nix.project' {
                src = final.haskell-nix.haskellLib.cleanGit {
                  name = "dex";
                  src = ./.;
                };
                compiler-nix-name = "ghc884";
                shell.tools = {
                  cabal = {};
                  hlint = {};
                  haskell-language-server = {};
                };
                shell.buildInputs = with pkgs; [
                  nixpkgs-fmt
                ];
              };
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
        flake = pkgs.dexProject.flake {};
      in flake // {
        defaultPackage = flake.packages."dex:exe:dex";
      });
}
