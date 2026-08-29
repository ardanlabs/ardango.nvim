#!/usr/bin/env bash
# One-time bootstrap for the dev/ Neovim playground: clones the runtime
# dependencies (nui.nvim, nvim-treesitter, and telescope.nvim + its
# plenary.nvim dependency, for the opts.telescope result view) and
# installs the Go treesitter parser. Safe to re-run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="$here/.deps"
mkdir -p "$deps"

nvim="${NVIM:-nvim}"
if ! "$nvim" --headless -c 'lua if vim.fn.has("nvim-0.11") ~= 1 then os.exit(1) end' -c 'qa' 2>/dev/null; then
  echo "warning: '$nvim' is older than Neovim 0.11 - telescope.nvim's" \
       "current release needs 0.11+. Set NVIM=/path/to/newer/nvim and" \
       "re-run if this 'nvim' isn't your normal one (e.g. an older one" \
       "pinned by this repo's own shell.nix)." >&2
fi

if [ ! -d "$deps/nui.nvim" ]; then
  git clone --depth 1 https://github.com/MunifTanjim/nui.nvim.git "$deps/nui.nvim"
fi

if [ ! -d "$deps/nvim-treesitter" ]; then
  # "master" is the legacy branch with the :TSInstall / configs.setup API
  # used by dev/init.lua; the "main" branch is a newer rewrite that needs
  # a much newer Neovim.
  git clone --depth 1 -b master https://github.com/nvim-treesitter/nvim-treesitter.git "$deps/nvim-treesitter"
fi

if [ ! -d "$deps/plenary.nvim" ]; then
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git "$deps/plenary.nvim"
fi

if [ ! -d "$deps/telescope.nvim" ]; then
  git clone --depth 1 https://github.com/nvim-telescope/telescope.nvim.git "$deps/telescope.nvim"
fi

"$nvim" --clean --headless -u "$here/init.lua" -c "TSInstallSync! go" -c "qa"

# markdown/markdown_inline aren't required by ardango.nvim itself, but
# SignatureInStatusLine's opts.float opens the hover content through
# Neovim's own vim.lsp.util.open_floating_preview, which is markdown -
# without these installed, Neovim's built-in highlighter throws a noisy
# (but harmless) error on any hover containing a fenced code block.
"$nvim" --clean --headless -u "$here/init.lua" -c "TSInstallSync! markdown markdown_inline" -c "qa"

# Build the Delve proxy helper used by the Debug* commands (lua/ardango/debug.lua
# spawns bin/ardango-dbg). Needs the Go toolchain; skipped with a warning if
# `go` isn't on PATH (the Debug* commands then just error until it's built).
root="$(cd "$here/.." && pwd)"
if command -v go >/dev/null 2>&1; then
  ( cd "$root" && go build -o bin/ardango-dbg ./cmd/ardango-dbg )
  echo "built bin/ardango-dbg"
else
  echo "warning: 'go' not found - skipping bin/ardango-dbg build (needed for the Debug* commands)" >&2
fi

echo "dev environment ready. Try:"
echo "  $nvim --clean -u dev/init.lua dev/testdata/sample_test.go"
