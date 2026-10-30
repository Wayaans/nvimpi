-- Model choice: setup()'s `model`, else the one :NvimpiModel saved to nvimpi.json.
-- The file is re-read on every request, so a change from another Neovim instance applies.
local runner = require("nvimpi.runner")

local M = {}

--- Internal: the saved-model file. Tests point it at a temp dir.
M.path = vim.fs.joinpath(vim.fn.stdpath("data"), "nvimpi.json")

--- Internal: whether the invalid-file warning was shown since the file was last valid.
M.warned = false

local REFUSAL = "nvimpi: model is set in setup(): remove it there to use :NvimpiModel"

local function notify(message, level)
  vim.notify(message, level, { title = "nvimpi" })
end

local function setup_model()
  local model = require("nvimpi").config.model
  return model ~= nil and model ~= "" and model or nil
end

--- The saved model, nil when there is no file. An unreadable or invalid file is unset, with the reason.
---@return string? model
---@return string? problem
local function saved_model()
  if not vim.uv.fs_stat(M.path) then
    return nil
  end
  local file, open_error = io.open(M.path, "r")
  if not file then
    return nil, open_error
  end
  local text = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, "not valid JSON"
  end
  if type(value) ~= "table" or type(value.model) ~= "string" or value.model == "" then
    return nil, 'expected {"model":"provider/id"}'
  end
  return value.model
end

--- The current model and where it came from, without side effects. `problem` is why
--- nvimpi.json was ignored, if it was.
---@return { model: string, source: "setup()"|"nvimpi.json" }? current
---@return string? problem
function M.current()
  local model = setup_model()
  if model then
    return { model = model, source = "setup()" }
  end
  local saved, problem = saved_model()
  return saved and { model = saved, source = "nvimpi.json" } or nil, problem
end

--- The model for a request: like `current()`, warning once while nvimpi.json stays invalid.
---@return string?
function M.resolve()
  local current, problem = M.current()
  if problem and not M.warned then
    notify(("nvimpi: ignoring %s: %s"):format(M.path, problem), vim.log.levels.WARN)
  end
  M.warned = problem ~= nil
  return current and current.model
end

---@param model string
local function save(model)
  local ok, write_error = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(M.path), "p")
    assert(vim.fn.writefile({ vim.json.encode({ model = model }) }, M.path) == 0, "write failed")
  end)
  if not ok then
    notify(("nvimpi: cannot save the model to %s: %s"):format(M.path, write_error), vim.log.levels.ERROR)
    return
  end
  notify("nvimpi: model set to " .. model, vim.log.levels.INFO)
end

--- The providers with a setup() key. Only the ids: key values (and key functions) stay in
--- setup() until a request.
---@return string[]
local function setup_key_providers()
  local provider_ids = vim.tbl_keys(require("nvimpi").config.api_keys or {})
  table.sort(provider_ids)
  return provider_ids
end

--- The models the user can pick, or nil after showing why there are none.
---@return string[]?
local function pickable()
  local outcome = runner.list_models(setup_key_providers())
  if outcome.type ~= "models" then
    notify(outcome.message, vim.log.levels.ERROR)
  elseif #outcome.models == 0 then
    notify(
      "nvimpi: no provider has credentials: log in with pi, set a provider's API key env var, or set api_keys in setup()",
      vim.log.levels.ERROR
    )
  else
    return outcome.models
  end
end

--- :NvimpiModel [provider/id]: saves the given model, or picks one from the list.
---@param arg string the command argument, "" for none
function M.command(arg)
  if setup_model() then
    notify(REFUSAL, vim.log.levels.ERROR)
    return
  end
  if arg ~= "" then
    if not arg:match("^[^/]+/.+$") then
      notify("nvimpi: expected provider/id, got " .. arg, vim.log.levels.ERROR)
      return
    end
    save(arg)
    return
  end
  local models = pickable()
  if models then
    vim.ui.select(models, { prompt = "nvimpi model" }, function(choice)
      if choice then
        save(choice)
      end
    end)
  end
end

--- Completion for :NvimpiModel: listed models starting with `arglead`.
---@param arglead string
---@return string[]
function M.complete(arglead)
  if setup_model() then
    return {}
  end
  local outcome = runner.list_models(setup_key_providers())
  if outcome.type ~= "models" then
    return {}
  end
  return vim.tbl_filter(function(model)
    return vim.startswith(model, arglead)
  end, outcome.models)
end

return M
