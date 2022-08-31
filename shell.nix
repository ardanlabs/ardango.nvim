{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  nativeBuildInputs =
    let
      p = pkgs;
    in
    [
      p.lua5_3
      p.sumneko-lua-language-server
    ];
}

