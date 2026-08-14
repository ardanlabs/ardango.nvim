# dev playground

A throwaway Neovim setup for manually exercising ardango.nvim, with a
small Go fixture package to run tests/builds/tag commands against.
Nothing here is required to *use* the plugin — it only exists to make
it easy to see a change working.

## One-time setup

```sh
./dev/setup.sh
```

Clones `nui.nvim` and `nvim-treesitter` into `dev/.deps/` (gitignored)
and installs the Go treesitter parser. Safe to re-run.

## Launching

Always launch from inside `dev/testdata/` (that's where `go.mod`
lives, and the plugin runs `go build`/`go test` relative to Neovim's
cwd) and always with `--clean`, so your personal Neovim config doesn't
get loaded on top of `dev/init.lua`:

```sh
cd dev/testdata
nvim --clean -u ../init.lua sample_test.go
```

`dev/init.lua` sets `<leader>` to `<space>` and wires up the same keymaps
the README recommends:

- `<leader>gt` — `RunCurrTest`
- `<leader>gp` — `BuildCurrPackage`
- `<leader>taf` / `<leader>tas` — add tag to field / struct
- `<leader>trf` / `<leader>trs` — remove tag from field / struct

## Fixtures

- `sample.go` — a `Person` struct for the tag commands.
- `sample_test.go` — `TestGreetPass` (put the cursor inside it, run
  `<leader>gt`, expect a success notification) and `TestGreetFail`
  (same, but expect the failure to open in the quickfix list).
- `broken_example.go.txt` — inert by default (`go build ./...` stays
  green). To see `BuildCurrPackage`'s failure path, copy it to
  `broken.go`, run `<leader>gp` inside `dev/testdata`, then delete
  `broken.go` again:

  ```sh
  cp broken_example.go.txt broken.go
  nvim --clean -u ../init.lua broken.go   # <leader>gp
  rm broken.go
  ```
