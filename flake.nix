{
  description = "Ardan's Go utilities Neovim plugin";

  inputs = {
    # Pinned explicitly (rather than the flake registry's indirect
    # `nixpkgs`) so `nix develop` resolves the same on any machine.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          devShells.default = import ./shell.nix { inherit pkgs; };
        }
      );
}
