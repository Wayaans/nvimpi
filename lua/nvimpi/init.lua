local request = require("nvimpi.request")
local runner = require("nvimpi.runner")
local apply = require("nvimpi.apply")
local feedback = require("nvimpi.feedback")

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

local function fail(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "nvimpi" })
end

--- Internal: the Instruction of the last failed request, prefilled into the next prompt.
--- One value, not history. A field so tests can clear it.
---@type string?
M.failed_instruction = nil

---@return { provider: string, id: string }? model
---@return string? error
local function current_model()
  local model = M.config.model
  if model == nil or model == "" then
    return nil, "nvimpi: no model set. Run :NvimpiModel or set model in setup()"
  end
  local provider, id = model:match("^([^/]+)/(.+)$")
  if not provider then
    return nil, ("nvimpi: unknown model %s: run :NvimpiModel"):format(model)
  end
  return { provider = provider, id = id }
end

--- The setup key for `provider`, if any: a function is called now, and the result trimmed.
--- The error never contains the key.
---@param provider string
---@return string? key nil when there is no entry
---@return string? error
local function setup_key(provider)
  local entry = (M.config.api_keys or {})[provider]
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

--- The current Visual selection. A charwise end past the last character stops at the line end.
---@param buf integer
---@param mode "v"|"V"
---@return nvimpi.Target
local function visual_target(buf, mode)
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
local function cursor_target(win)
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  return { linewise = false, start_row = row - 1, start_col = col, end_row = row - 1, end_col = col }
end

--- The action for user mappings: with a Visual selection, prompt for an Instruction and Rewrite it;
--- with nothing selected, Insert at the cursor.
function M.prompt()
  if runner.running() then
    vim.notify("nvimpi: a request is already running (<C-c> cancels it)", vim.log.levels.WARN, { title = "nvimpi" })
    return
  end
  local mode = vim.fn.mode()
  if mode == "\22" then
    return -- blockwise Visual is not supported
  end
  local model, model_error = current_model()
  if not model then
    fail(model_error)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local action, target, label
  if mode == "v" or mode == "V" then
    action, target = "rewrite", visual_target(buf, mode)
    vim.cmd("normal! \27") -- leave Visual mode before prompting
    label = ("Rewrite %d,%d❯ "):format(target.start_row + 1, target.end_row + 1)
  else
    action, target = "insert", cursor_target(0)
    label = ("Insert %d:%d❯ "):format(target.start_row + 1, target.start_col + 1)
  end

  vim.ui.input({ prompt = label, default = M.failed_instruction }, function(instruction)
    if instruction == nil or instruction == "" then
      return
    end
    M.failed_instruction = nil
    local api_key, key_error = setup_key(model.provider)
    if key_error then
      M.failed_instruction = instruction
      fail(key_error)
      return
    end
    local text = request.rewrite_text(buf, target)
    local line = {
      mode = action,
      instruction = instruction,
      before = text.before,
      selection = text.selection,
      after = text.after,
      filetype = vim.bo[buf].filetype,
      model = model,
      api_key = api_key, -- only on stdin: never in argv or the environment
    }
    local tracked = apply.track(buf, target)
    feedback.start(buf, target.start_row, target.end_row, runner.cancel)
    runner.run(line, { timeout_ms = M.config.timeout_ms }, function(outcome)
      feedback.stop()
      local kind = outcome.type
      if kind == "result" then
        local discarded = apply.apply(tracked, outcome.text)
        if discarded then
          M.failed_instruction = instruction
          vim.notify(discarded, vim.log.levels.WARN, { title = "nvimpi" })
        end
        return
      end
      apply.release(tracked)
      if kind == "error" or kind == "crash" or kind == "timeout" then
        M.failed_instruction = instruction
        fail(outcome.message)
      elseif kind ~= "cancel" then -- a cancel is silent and does not refill
        error("nvimpi: unhandled outcome " .. tostring(kind))
      end
    end)
  end)
end

--- For the user's statusline: a spinner and the elapsed time while a request runs, "" when idle.
---@return string
function M.status()
  return feedback.status()
end

return M
