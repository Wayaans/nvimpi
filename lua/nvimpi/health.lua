-- :checkhealth nvimpi. Never calls an api_keys function, runs a key command, or shows a key.
local runner = require("nvimpi.runner")

local M = {}

--- Reports node and returns whether it is usable.
local function check_node()
  local ok, found = runner.node_status(true)
  if ok then
    vim.health.ok("node " .. found)
  elseif found == nil then
    vim.health.error("node not found on PATH", { "Install Node 22.19 or newer" })
  else
    local version = found ~= "" and found or "(unknown version)"
    vim.health.error(("node %s is too old: nvimpi needs 22.19 or newer"):format(version), { "Install Node 22.19 or newer" })
  end
  return ok
end

--- Reports the bundled sidecar and returns whether it is present.
local function check_sidecar()
  if vim.uv.fs_stat(runner.sidecar) then
    vim.health.ok("sidecar bundle found: " .. runner.sidecar)
    return true
  end
  vim.health.error("sidecar bundle missing: " .. runner.sidecar, { "Reinstall nvimpi" })
  return false
end

--- Reports the current model and returns its provider, or nil when there is no usable model.
---@return string?
local function check_model()
  local current, problem = require("nvimpi.model").current()
  if problem then
    vim.health.warn(("ignoring %s: %s"):format(require("nvimpi.model").path, problem))
  end
  if not current then
    vim.health.warn("no model set", { "Run :NvimpiModel to pick one, or set model in setup()" })
    return nil
  end
  local model = require("nvimpi.model").parse(current.model)
  if not model then
    vim.health.error(("model %s is not provider/id"):format(current.model), { "Run :NvimpiModel to pick one" })
    return nil
  end
  vim.health.ok(("model %s (from %s)"):format(current.model, current.source))
  return model.provider
end

--- Reports what covers `provider`: a setup() key wins over auth.json and env, as in a request.
---@param provider string
---@param can_query boolean whether node and the sidecar are usable
local function check_credentials(provider, can_query)
  local entry = (require("nvimpi").config.api_keys or {})[provider]
  local setup_key = ("api_keys.%s"):format(provider)
  if entry ~= nil then
    if vim.is_callable(entry) or (type(entry) == "string" and vim.trim(entry) ~= "") then
      vim.health.ok(("%s credentials: %s in setup()"):format(provider, setup_key))
    elseif type(entry) == "string" then
      vim.health.error(setup_key .. " is empty", { "Set it to the key, or remove it" })
    else
      vim.health.error(("%s must be a string or a function, got %s"):format(setup_key, type(entry)))
    end
    return
  end
  if not can_query then
    vim.health.warn(provider .. " credentials not checked: node or the sidecar is unavailable")
    return
  end
  local outcome = runner.credential_source(provider)
  if outcome.type ~= "source" then
    vim.health.error(outcome.message)
  elseif outcome.source == "auth.json" then
    vim.health.ok(provider .. " credentials: pi's auth.json")
  elseif outcome.source == "env" then
    vim.health.ok(provider .. " credentials: an environment variable")
  elseif outcome.source == "unknown" then
    vim.health.error("unknown provider " .. provider, { "Run :NvimpiModel to pick a model" })
  else
    vim.health.error("no credentials for " .. provider, {
      ("Set %s in setup(), log in with pi (auth.json), or set the provider's API key environment variable"):format(setup_key),
    })
  end
end

function M.check()
  vim.health.start("nvimpi")

  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12+")
  else
    vim.health.error("Neovim 0.12+ required", { "Upgrade Neovim" })
  end

  local node_ok = check_node()
  local sidecar_ok = check_sidecar()
  local provider = check_model()
  if provider then
    check_credentials(provider, node_ok and sidecar_ok)
  end
end

return M
