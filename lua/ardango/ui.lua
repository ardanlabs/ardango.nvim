local Popup = require('nui.popup')
local nuievent = require('nui.utils.autocmd').event
local api = vim.api

local M = {}

-- Show results opens up a popup showing the received data.
M.show_results = function(data)
  if data and not (data[1] == "") then
    -- Write into a hidden buffer.
    local popBuffer = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(popBuffer, 0, -1, false, data)

    -- Create the popup
    local popup = Popup {
      relative = "cursor",
      position = 0,
      size = "50%",
      enter = true,
      bufnr = popBuffer,
    }

    popup:mount()

    popup:on({ nuievent.BufLeave }, function()
      api.nvim_buf_delete(popBuffer, { force = true })
      popup:unmount()
    end, { once = true })

    popup:map("n", "<esc>", function()
      api.nvim_buf_delete(popBuffer, { force = true })
      popup:unmount()
    end, { silent = true })
  end
end

return M
