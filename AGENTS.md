# Agent instructions

ardango.nvim is a small Neovim plugin (Lua) that adds Go-focused editor
commands: run the test under the cursor, build the current package,
organize imports, show hover signature in the statusline, and add/remove
struct tags via Treesitter. See `README.md` for the user-facing feature
list and `TODO.md` for planned work.

## Testing

There is no automated test suite. Before considering any change to
`lua/ardango/*.lua` done, verify it manually following **`TESTING.md`** —
it has the fixture setup (`dev/`), the exact launch invocation (including
why `--clean` is required), and the manual test matrix to run. Read it in
full before attempting to run or verify the plugin; skipping steps in it
(e.g. launching without `--clean`, or launching outside
`dev/testdata/`) produces misleading failures that look like plugin bugs
but aren't.
