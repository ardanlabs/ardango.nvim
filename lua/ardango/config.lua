local M = {}

-- Defaults match the popup's previous hardcoded values.
M.defaults = {
  popup = {
    border = "rounded",
    size = "50%",
    relative = "cursor",
    position = 0,
  },
}

M.options = vim.deepcopy(M.defaults)

-- setup lets a user override plugin-wide config, currently just the
-- results popup's border/size/relative/position (passed straight
-- through to nui.Popup - see :h nui.popup for accepted shapes).
--
--   require("ardango").setup({
--     popup = { border = "single", size = "80%" },
--   })
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
