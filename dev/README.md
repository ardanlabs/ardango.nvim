# dev playground

A throwaway Neovim setup for manually exercising ardango.nvim, with a
small Go fixture package to run tests/builds/tag commands against.
Nothing here is required to *use* the plugin — it only exists to make
it easy to see a change working.

Quick start (run from this repo's `nix develop`/`nix-shell`, which pins a
Neovim new enough for everything here):

```sh
./dev/setup.sh
cd dev/testdata
nvim --clean -u ../init.lua sample_test.go
```

For everything else — dependencies installed, keymaps, fixtures, the
manual test matrix, and the environment gotchas (Neovim version, why
`--clean` is required, etc.) — see **[`../TESTING.md`](../TESTING.md)**,
which is kept up to date as the source of truth; this file intentionally
doesn't duplicate it.
