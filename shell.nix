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

      # Go toolchain for the dev/testdata fixture (test/build commands) and
      # for building the cmd/ardango-dbg helper; delve (`dlv`) is the
      # backend the Debug* commands drive. Pinned to the 1.27.x line (patch
      # updates only) - bump to go_1_28 etc. deliberately as needed.
      p.go_1_27
      p.delve
    ];
}
