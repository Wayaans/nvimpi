-- Feedback while a request runs: a highlight moving down the target lines (a pulse when the
-- target is one line), the status() spinner and elapsed time, and a Normal-mode <C-c> mapping
-- that exists only while the request runs. Nothing opens or takes focus.
local M = {}

local ns = vim.api.nvim_create_namespace("nvimpi.feedback")
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TICK_MS = 100
local PULSE_TICKS = 5 -- a one-line target is lit for this many ticks, then dark for as many

---@class nvimpi.Feedback
---@field buf integer
---@field first_row integer
---@field last_row integer
---@field tick integer
---@field started integer vim.uv.now() at start
---@field timer uv.uv_timer_t
---@field user_map table? the user's global <C-c> mapping, restored on stop

---@type nvimpi.Feedback?
local active

--- The user's global Normal-mode <C-c> mapping, as a mapset() dict, or nil.
local function global_ctrl_c()
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.lhs == "<C-C>" then
      return map
    end
  end
end

local function draw(state)
  local buf = state.buf
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local row
  local count = state.last_row - state.first_row + 1
  if count == 1 then
    if math.floor(state.tick / PULSE_TICKS) % 2 == 1 then
      return
    end
    row = state.first_row
  else
    row = state.first_row + state.tick % count
  end
  -- The buffer stays editable, so the target may have shrunk.
  row = math.min(row, vim.api.nvim_buf_line_count(buf) - 1)
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "NvimpiWorking" })
end

--- Starts the feedback for a request on rows first_row..last_row (0-based) of `buf`.
--- `on_cancel` runs when the user presses <C-c> in Normal mode.
---@param buf integer
---@param first_row integer
---@param last_row integer
---@param on_cancel fun()
function M.start(buf, first_row, last_row, on_cancel)
  assert(not active, "nvimpi: feedback already running")
  -- Set on every start: a :colorscheme clears default links.
  vim.api.nvim_set_hl(0, "NvimpiWorking", { link = "Visual", default = true })

  local state = {
    buf = buf,
    first_row = first_row,
    last_row = last_row,
    tick = 0,
    started = vim.uv.now(),
    timer = assert(vim.uv.new_timer()),
    user_map = global_ctrl_c(),
  }
  active = state
  vim.keymap.set("n", "<C-c>", on_cancel, { desc = "nvimpi: cancel the running request" })
  draw(state)
  state.timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(function()
    if active ~= state then
      return -- a tick queued before stop()
    end
    state.tick = state.tick + 1
    draw(state)
    vim.cmd("redrawstatus")
  end))
end

--- Stops the animation, clears the highlight and restores the user's <C-c>. Safe to call when idle.
function M.stop()
  local state = active
  if not state then
    return
  end
  active = nil
  state.timer:stop()
  state.timer:close()
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  end
  pcall(vim.keymap.del, "n", "<C-c>")
  if state.user_map then
    vim.fn.mapset(state.user_map)
  end
  vim.cmd("redrawstatus")
end

--- A spinner and the elapsed time while a request runs, "" when idle.
---@return string
function M.status()
  local state = active
  if not state then
    return ""
  end
  local seconds = math.floor((vim.uv.now() - state.started) / 1000)
  return ("%s nvimpi %ds"):format(FRAMES[state.tick % #FRAMES + 1], seconds)
end

return M
