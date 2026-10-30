local request = require("nvimpi.request")
local runner = require("nvimpi.runner")
local apply = require("nvimpi.apply")
local feedback = require("nvimpi.feedback")
local model_choice = require("nvimpi.model")
local notify = require("nvimpi.notify")

local M = {}

---@class nvimpi.Config
---@field model? string "provider/id", split at the first "/"
---@field timeout_ms? number request time limit; the sidecar is killed after it
---@field api_keys? table<string, string|fun(): string> provider -> key, or a function returning it
local defaults = { timeout_ms = 120000 }

---@type nvimpi.Config
M.config = vim.deepcopy(defaults)

---@param opts? nvimpi.Config
function M.setup(opts)
  vim.validate("timeout_ms", (opts or {}).timeout_ms, "number", true)
  vim.validate("api_keys", (opts or {}).api_keys, "table", true)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

--- Internal: the Instruction of the last failed request, prefilled into the next prompt.
--- One value, not history. A field so tests can clear it.
---@type string?
M.failed_instruction = nil

--- Handles a finished request: applies a result, reports a failure, and stays silent on a cancel.
---@param tracked nvimpi.Tracked
---@param instruction string
---@param outcome nvimpi.Outcome
local function finish(tracked, instruction, outcome)
  feedback.stop()
  local kind = outcome.type
  if kind == "result" then
    local discarded = apply.apply(tracked, outcome.text)
    if discarded then
      M.failed_instruction = instruction
      notify(discarded, vim.log.levels.WARN)
    end
    return
  end
  apply.release(tracked)
  if kind == "error" or kind == "crash" or kind == "timeout" then
    M.failed_instruction = instruction
    notify(outcome.message, vim.log.levels.ERROR)
  elseif kind ~= "cancel" then -- a cancel is silent and does not refill
    error("nvimpi: unhandled outcome " .. tostring(kind))
  end
end

--- The action for user mappings: with a Visual selection, prompt for an Instruction and Rewrite it;
--- with nothing selected, Insert at the cursor.
function M.prompt()
  if runner.running() then
    notify("nvimpi: a request is already running (<C-c> cancels it)", vim.log.levels.WARN)
    return
  end
  local mode = vim.fn.mode()
  if mode == "\22" then
    return -- blockwise Visual is not supported
  end
  local model, model_error = model_choice.resolve()
  if not model then
    notify(model_error, vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local action, target, label
  if mode == "v" or mode == "V" then
    action, target = "rewrite", request.visual_target(buf, mode)
    vim.cmd("normal! \27") -- leave Visual mode before prompting
    label = ("Rewrite %d,%d❯ "):format(target.start_row + 1, target.end_row + 1)
  else
    action, target = "insert", request.cursor_target(0)
    label = ("Insert %d:%d❯ "):format(target.start_row + 1, target.start_col + 1)
  end

  vim.ui.input({ prompt = label, default = M.failed_instruction }, function(instruction)
    if instruction == nil or instruction == "" then
      return
    end
    M.failed_instruction = nil
    local api_key, key_error = request.api_key(M.config.api_keys, model.provider)
    if key_error then
      M.failed_instruction = instruction
      notify(key_error, vim.log.levels.ERROR)
      return
    end
    local line = request.build(buf, target, { mode = action, instruction = instruction, model = model, api_key = api_key })
    local tracked = apply.track(buf, target)
    feedback.start(buf, function()
      return apply.rows(tracked)
    end, runner.cancel)
    runner.run(line, { timeout_ms = M.config.timeout_ms }, function(outcome)
      finish(tracked, instruction, outcome)
    end)
  end)
end

--- For the user's statusline: a spinner and the elapsed time while a request runs, "" when idle.
---@return string
function M.status()
  return feedback.status()
end

return M
