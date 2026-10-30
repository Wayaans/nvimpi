local request = require("nvimpi.request")
local runner = require("nvimpi.runner")
local apply = require("nvimpi.apply")

local M = {}

---@class nvimpi.Config
---@field model? string "provider/id", split at the first "/"
local defaults = {}

---@type nvimpi.Config
M.config = vim.deepcopy(defaults)

---@param opts? nvimpi.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

local function fail(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "nvimpi" })
end

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

--- The action for user mappings: with a Visual selection, prompt for an Instruction and Rewrite it.
function M.prompt()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" then
    return
  end
  local model, model_error = current_model()
  if not model then
    fail(model_error)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local target = visual_target(buf, mode)
  vim.cmd("normal! \27") -- leave Visual mode before prompting

  local label = ("Rewrite %d,%d❯ "):format(target.start_row + 1, target.end_row + 1)
  vim.ui.input({ prompt = label }, function(instruction)
    if instruction == nil or instruction == "" then
      return
    end
    local text = request.rewrite_text(buf, target)
    local line = {
      mode = "rewrite",
      instruction = instruction,
      before = text.before,
      selection = text.selection,
      after = text.after,
      filetype = vim.bo[buf].filetype,
      model = model,
    }
    runner.run(line, function(outcome)
      if outcome.type == "result" then
        apply.apply(buf, target, outcome.text)
      else
        fail(outcome.message)
      end
    end)
  end)
end

return M
