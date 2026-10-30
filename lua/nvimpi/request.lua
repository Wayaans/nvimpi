-- Request builder: finds the target (a Visual selection or the cursor), resolves the setup()
-- key, and turns them into the request line. In its text fields, `before .. selection .. after`
-- reproduces that stretch of the buffer byte for byte, where every line ends with its newline.
local M = {}

local CONTEXT_LINES = 100

---@class nvimpi.Target
---@field linewise boolean
---@field start_row integer 0-based
---@field start_col integer 0-based byte column (charwise only)
---@field end_row integer 0-based, inclusive
---@field end_col integer 0-based byte column, exclusive (charwise only)

--- The current Visual selection. A charwise end past the last character stops at the line end.
---@param buf integer
---@param mode "v"|"V"
---@return nvimpi.Target
function M.visual_target(buf, mode)
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
    a, b = b, a
  end
  local sr, er = a[2] - 1, b[2] - 1
  if mode == "V" then
    return { linewise = true, start_row = sr, start_col = 0, end_row = er, end_col = 0 }
  end
  local first_line = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, true)[1]
  local last_line = vim.api.nvim_buf_get_lines(buf, er, er + 1, true)[1]
  -- getpos() gives the first byte of the last selected character; include all its bytes.
  local end_col = b[3] > #last_line and #last_line or b[3] + vim.str_utf_end(last_line, b[3])
  return { linewise = false, start_row = sr, start_col = math.min(a[3] - 1, #first_line), end_row = er, end_col = end_col }
end

--- An empty charwise range at the cursor: Insert puts text before the character under it.
---@param win integer
---@return nvimpi.Target
function M.cursor_target(win)
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  return { linewise = false, start_row = row - 1, start_col = col, end_row = row - 1, end_col = col }
end

--- The setup() key for `provider`, if any: a function is called now, and the result trimmed.
--- The error never contains the key.
---@param api_keys? table<string, string|fun(): string>
---@param provider string
---@return string? key nil when there is no entry
---@return string? error
function M.api_key(api_keys, provider)
  local entry = (api_keys or {})[provider]
  if entry == nil then
    return nil
  end
  local ok, key = true, entry
  if vim.is_callable(entry) then
    ok, key = pcall(entry)
  end
  local problem
  if not ok then
    problem = tostring(key)
  elseif type(key) ~= "string" then
    problem = "expected a string, got " .. type(key)
  elseif vim.trim(key) == "" then
    problem = "the key is empty"
  end
  if problem then
    return nil, ("nvimpi: api_keys.%s failed: %s"):format(provider, problem)
  end
  return vim.trim(key)
end

---@param lines string[]
local function with_newlines(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

--- Up to 100 full lines of Context on each side. A charwise target's partial first and last
--- lines are Context too (an Insert's target is an empty charwise range); a linewise
--- selection's newline stays in `after`.
---@param buf integer
---@param target nvimpi.Target
---@return { before: string, selection: string, after: string }
local function text_fields(buf, target)
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

--- The request line for the sidecar.
---@param buf integer
---@param target nvimpi.Target
---@param fields { mode: "rewrite"|"insert", instruction: string, model: { provider: string, id: string }, api_key: string? }
---@return table
function M.build(buf, target, fields)
  local text = text_fields(buf, target)
  return {
    mode = fields.mode,
    instruction = fields.instruction,
    before = text.before,
    selection = text.selection,
    after = text.after,
    filetype = vim.bo[buf].filetype,
    model = fields.model,
    api_key = fields.api_key, -- only on stdin: never in argv or the environment
  }
end

return M
