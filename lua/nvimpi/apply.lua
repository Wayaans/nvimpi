-- Applier: tracks the target with an extmark while the request runs, then puts the model's
-- text in its place as one undo step, unless the buffer closed or the target's text changed.
local M = {}

local ns = vim.api.nvim_create_namespace("nvimpi.apply")

--- A target being tracked. The extmark spans the guarded text: the selection for a charwise
--- Rewrite, whole lines for a linewise Rewrite, and the cursor line for an Insert (an Insert's own
--- range is empty, so any edit on its line counts as inside). Its start moves with text typed
--- right before it and its end stays put for text typed right after it, so both count as outside.
---@class nvimpi.Tracked
---@field buf integer
---@field target nvimpi.Target
---@field mark integer
---@field guarded string the guarded text when the request started

---@param target nvimpi.Target
local function guards_lines(target)
  return target.linewise or (target.start_row == target.end_row and target.start_col == target.end_col)
end

---@param buf integer
---@param target nvimpi.Target
---@return nvimpi.Tracked
function M.track(buf, target)
  local start_col, end_col = target.start_col, target.end_col
  if guards_lines(target) then
    start_col = 0
    end_col = #vim.api.nvim_buf_get_lines(buf, target.end_row, target.end_row + 1, true)[1]
  end
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, target.start_row, start_col, {
    end_row = target.end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = false,
  })
  local guarded = vim.api.nvim_buf_get_text(buf, target.start_row, start_col, target.end_row, end_col, {})
  return { buf = buf, target = target, mark = mark, guarded = table.concat(guarded, "\n") }
end

--- Stops tracking without applying anything (a cancel or a failure).
---@param tracked nvimpi.Tracked
function M.release(tracked)
  if vim.api.nvim_buf_is_valid(tracked.buf) then
    vim.api.nvim_buf_del_extmark(tracked.buf, ns, tracked.mark)
  end
end

--- Where the target is now, or nil when its guarded text changed.
---@param tracked nvimpi.Tracked
---@return nvimpi.Target?
local function current_target(tracked)
  local pos = vim.api.nvim_buf_get_extmark_by_id(tracked.buf, ns, tracked.mark, { details = true })
  local sr, sc, details = pos[1], pos[2], pos[3]
  if sr == nil or details == nil then
    return nil
  end
  local er, ec = details.end_row, details.end_col
  if er < sr or (er == sr and ec < sc) then
    return nil -- the edges crossed: the text between them was replaced
  end
  local old = tracked.target
  if guards_lines(old) then
    -- Compare whole lines: text typed at the very start of the first line is inside too.
    local lines = vim.api.nvim_buf_get_lines(tracked.buf, sr, er + 1, true)
    if table.concat(lines, "\n") ~= tracked.guarded then
      return nil
    end
    -- Same lines, so the columns still hold; only the rows moved.
    return { linewise = old.linewise, start_row = sr, start_col = old.start_col, end_row = er, end_col = old.end_col }
  end
  if table.concat(vim.api.nvim_buf_get_text(tracked.buf, sr, sc, er, ec, {}), "\n") ~= tracked.guarded then
    return nil
  end
  return { linewise = false, start_row = sr, start_col = sc, end_row = er, end_col = ec }
end

---@param buf integer
---@param target nvimpi.Target
---@param text string
local function replace(buf, target, text)
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

--- Applies `text` to the tracked target and stops tracking it.
---@param tracked nvimpi.Tracked
---@param text string
---@return string? discarded the WARN to show when the result was dropped
function M.apply(tracked, text)
  if not vim.api.nvim_buf_is_loaded(tracked.buf) then
    return "nvimpi: buffer closed, result discarded"
  end
  local target = current_target(tracked)
  M.release(tracked)
  if not target then
    return "nvimpi: text changed, result discarded"
  end
  replace(tracked.buf, target, text)
end

return M
