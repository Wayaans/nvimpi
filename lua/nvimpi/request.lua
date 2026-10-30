-- Request builder: turns a buffer and a target into the request's text fields.
-- `before .. selection .. after` reproduces that stretch of the buffer byte for byte,
-- where every line ends with its newline.
local M = {}

local CONTEXT_LINES = 100

---@class nvimpi.Target
---@field linewise boolean
---@field start_row integer 0-based
---@field start_col integer 0-based byte column (charwise only)
---@field end_row integer 0-based, inclusive
---@field end_col integer 0-based byte column, exclusive (charwise only)

---@param lines string[]
local function with_newlines(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

--- Up to 100 full lines of Context on each side. A charwise selection's partial
--- first and last lines are Context too; a linewise selection's newline stays in `after`.
---@param buf integer
---@param target nvimpi.Target
---@return { before: string, selection: string, after: string }
function M.rewrite_text(buf, target)
  local sr, er = target.start_row, target.end_row
  local first = math.max(0, sr - CONTEXT_LINES)
  local last = math.min(vim.api.nvim_buf_line_count(buf), er + 1 + CONTEXT_LINES)
  local above = with_newlines(vim.api.nvim_buf_get_lines(buf, first, sr, true))
  local below = with_newlines(vim.api.nvim_buf_get_lines(buf, er + 1, last, true))

  if target.linewise then
    local selected = vim.api.nvim_buf_get_lines(buf, sr, er + 1, true)
    return { before = above, selection = table.concat(selected, "\n"), after = "\n" .. below }
  end

  local first_line = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, true)[1]
  local last_line = vim.api.nvim_buf_get_lines(buf, er, er + 1, true)[1]
  local selected = vim.api.nvim_buf_get_text(buf, sr, target.start_col, er, target.end_col, {})
  return {
    before = above .. first_line:sub(1, target.start_col),
    selection = table.concat(selected, "\n"),
    after = last_line:sub(target.end_col + 1) .. "\n" .. below,
  }
end

return M
