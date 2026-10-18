{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Support a particular subset of the Nix systems
    # systems.url = "github:nix-systems/default";
  };

  outputs =
    { nixpkgs, ... }:
    let
      eachSystem =
        f:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.pnpm
            pkgs.typescript
            pkgs.typescript-language-server
            
            pkgs.uv
            pkgs.python314Packages.setuptools
            pkgs.python314Packages.wheel
          ];
        };
      });
    };
}
