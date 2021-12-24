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
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.follows = "haskell-nix/flake-utils";
  };

  outputs = { self, nixpkgs, haskell-nix, utils, ... }:
    utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" ] (system:
      let
        pkgs = haskell-nix.legacyPackages.${system};
        hsPkgs = pkgs.haskellPackages;

        haskellNix = pkgs.haskell-nix.cabalProject {
          src = pkgs.haskell-nix.haskellLib.cleanGit {
            name = "dex";
            src = ./.;
          };
          compiler-nix-name = "ghc884";
        };

        dex = haskellNix.dex.components.exes.dex;
      in {
        packages.dex = dex;

        devShell = haskellNix.shellFor {
          packages = p: [ p.dex ];
          withHoogle = false;
          tools = {
            cabal = "latest";
            haskell-language-server = "latest";
          };
          nativeBuildInputs = [
            haskellNix.dex.project.roots
          ];
          exactDeps = true;
        };

        defaultPackage = dex;
      });
}
