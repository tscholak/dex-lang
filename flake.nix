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
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.follows = "haskellNix/flake-utils";
  };

  outputs = { self, nixpkgs, haskellNix, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" ] (system:
      let
        overlays = [
          haskellNix.overlay
          (final: prev: {
            llvm-config = prev.llvmPackages_12.llvm;
            dexProject =
              final.haskell-nix.cabalProject' {
                src = final.haskell-nix.haskellLib.cleanGit {
                  name = "dex";
                  src = ./.;
                };
                compiler-nix-name = "ghc8107";
                shell.tools = {
                  cabal = {};
                  hlint = {};
                  haskell-language-server = {};
                };
                shell.buildInputs = with final; [
                  nixpkgs-fmt
                ];
              };
          })
        ];
        pkgs =
          let
            nixpkgsFun = import nixpkgs;
          in nixpkgsFun {
            inherit system;
            inherit (haskellNix) config;
            overlays = [
              (final: prev: {
                pkgsLLVM12 = nixpkgsFun {
                  inherit system;
                  inherit (haskellNix) config;
                  overlays = [
                    (final': prev': {
                      stdenv = prev.llvmPackages_12.stdenv;
                    })
                  ] ++ overlays;
                };
              })
            ] ++ overlays;
          };
        flake = pkgs.pkgsLLVM12.dexProject.flake {};
      in flake // {
        defaultPackage = flake.packages."dex:exe:dex";
      });
}
