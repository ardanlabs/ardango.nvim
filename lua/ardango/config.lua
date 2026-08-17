local M = {}

-- Defaults match the popup's previous hardcoded values.
M.defaults = {
  popup = {
    border = "rounded",
    size = "50%",
    relative = "cursor",
    position = 0,
  },
  -- Options offered (via <Tab>-toggle) in the tag value/options prompt
  -- (AddTagToField/AddTagsToStruct). "-" is special-cased by that prompt
  -- to win over everything else, since a bare `-` means "skip this field"
  -- per Go tag convention - keep that in mind if you remove it here.
  tag_options = { "omitempty", "-", "required" },
}

M.options = vim.deepcopy(M.defaults)

-- setup lets a user override plugin-wide config: the results popup's
-- border/size/relative/position (passed straight through to nui.Popup -
-- see :h nui.popup for accepted shapes), and the tag_options list offered
-- by the tag value/options prompt.
--
--   require("ardango").setup({
--     popup = { border = "single", size = "80%" },
--     tag_options = { "omitempty", "-", "required", "unique", "index" },
--   })
--
-- tag_options replaces the default list entirely rather than merging with
-- it (vim.tbl_deep_extend merges array indices, not whole arrays, which
-- would leave stray defaults behind for a shorter custom list).
M.setup = function(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.tag_options then
    M.options.tag_options = vim.deepcopy(opts.tag_options)
  end
end

return M
