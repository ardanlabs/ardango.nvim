#!/usr/bin/env bash
# One-time bootstrap for the dev/ Neovim playground: clones the two
# runtime dependencies (nui.nvim, nvim-treesitter) and installs the Go
# treesitter parser. Safe to re-run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="$here/.deps"
mkdir -p "$deps"

if [ ! -d "$deps/nui.nvim" ]; then
  git clone --depth 1 https://github.com/MunifTanjim/nui.nvim.git "$deps/nui.nvim"
fi

if [ ! -d "$deps/nvim-treesitter" ]; then
  # "master" is the legacy branch with the :TSInstall / configs.setup API
  # used by dev/init.lua; the "main" branch is a newer rewrite that needs
  # a much newer Neovim.
  git clone --depth 1 -b master https://github.com/nvim-treesitter/nvim-treesitter.git "$deps/nvim-treesitter"
fi

nvim --clean --headless -u "$here/init.lua" -c "TSInstallSync! go" -c "qa"

echo "dev environment ready. Try:"
echo "  nvim --clean -u dev/init.lua dev/testdata/sample_test.go"
