-- Applier: puts the model's text in place of the target as one undo step.
local M = {}

---@param buf integer
---@param target nvimpi.Target
---@param text string
function M.apply(buf, target, text)
  local empty_range = not target.linewise
    and target.start_row == target.end_row
    and target.start_col == target.end_col
  if text == "" and empty_range then
    return -- nothing to change, so no undo step either (an empty Insert)
  end
  -- Start a new undo block so the change never merges with the user's last edit.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("let &undolevels = &undolevels")
  end)
  local lines = vim.split(text, "\n", { plain = true })
  if target.linewise then
    -- An empty reply deletes the selected lines rather than leaving one empty line.
    vim.api.nvim_buf_set_lines(buf, target.start_row, target.end_row + 1, true, text == "" and {} or lines)
  else
    vim.api.nvim_buf_set_text(buf, target.start_row, target.start_col, target.end_row, target.end_col, lines)
  end
end

return M
