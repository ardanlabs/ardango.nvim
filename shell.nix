{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  nativeBuildInputs =
    let
      p = pkgs;
    in
    [
      p.zsh
      p.neovim
      p.lua5_3
      p.lua-language-server
    ];
}

