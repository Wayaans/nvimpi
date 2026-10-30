-- Runner: checks node, spawns one sidecar per request, writes the request line, closes stdin,
-- and turns the single stdout line (or its absence) into an outcome.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- Internal: the bundled sidecar, which :checkhealth looks for.
M.sidecar = root .. "/sidecar/dist/sidecar.mjs"

--- Internal, not a setup() option: the sidecar command. Tests swap in a fake script.
M.command = { "node", M.sidecar }

--- Internal: the `node` the version check looks for on PATH. Tests swap in a fake script.
M.node = "node"

--- Internal: `node --version` output, cached for the session after the first request.
---@type string?
M.node_version = nil

local STDERR_TAIL_LINES = 10
local LIST_TIMEOUT_MS = 10000
local SIGTERM = 15

---@alias nvimpi.Outcome
---| { type: "result", text: string }
---| { type: "error", message: string } a sidecar error line, or a failure before spawning
---| { type: "crash", message: string }
---| { type: "timeout", message: string }
---| { type: "cancel" }

---@param version string
---@return boolean
local function supported(version)
  local major, minor = version:match("^v(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not major or not minor then
    return false
  end
  return major > 22 or (major == 22 and minor >= 19)
end

--- Whether node is usable (on PATH and 22.19+), and what was found: the version, "" when
--- `node --version` printed nothing, or nil when node is not on PATH. The version is cached.
---@return boolean ok
---@return string? found
function M.node_status()
  if vim.fn.executable(M.node) == 0 then
    return false, nil
  end
  if M.node_version == nil then
    local ok, obj = pcall(function()
      return vim.system({ M.node, "--version" }, { text = true }):wait(5000)
    end)
    M.node_version = ok and vim.trim(obj.stdout or "") or ""
  end
  return supported(M.node_version), M.node_version
end

--- nil when node is usable, otherwise the message to show.
---@return string?
local function node_problem()
  local ok, found = M.node_status()
  if ok then
    return nil
  end
  return ("nvimpi: Node 22.19+ required (found %s). Run :checkhealth nvimpi"):format(
    found ~= nil and found ~= "" and found or "none"
  )
end

---@param stderr string?
---@return string
local function stderr_tail(stderr)
  local lines = vim.split(vim.trim(stderr or ""), "\n", { plain = true })
  if lines[1] == "" then
    return ""
  end
  return "\n" .. table.concat(lines, "\n", math.max(1, #lines - STDERR_TAIL_LINES + 1))
end

--- The outcome of a finished sidecar: what `accept` makes of its stdout line, an error line,
--- or else a timeout or crash.
---@param obj vim.SystemCompleted
---@param timeout_ms number
---@param accept fun(response: table): table? the success outcome, or nil when `response` is not one
---@return table
local function outcome_of(obj, timeout_ms, accept)
  -- vim.system reports its own timeout as code 124 after sending TERM.
  if obj.code == 124 and obj.signal == SIGTERM then
    return { type = "timeout", message = ("nvimpi: timed out after %gs"):format(timeout_ms / 1000) }
  end
  local ok, response = pcall(vim.json.decode, (obj.stdout or ""):match("^[^\n]*"))
  if ok and type(response) == "table" then
    local outcome = accept(response)
    if outcome then
      return outcome
    elseif response.type == "error" and type(response.message) == "string" then
      return { type = "error", message = response.message }
    end
  end
  local how = obj.signal ~= 0 and ("signal %d"):format(obj.signal) or ("exit %d"):format(obj.code)
  return { type = "crash", message = ("nvimpi: sidecar crashed (%s)%s"):format(how, stderr_tail(obj.stderr)) }
end

---@param response table
---@return nvimpi.Outcome?
local function result_of(response)
  if response.type == "result" and type(response.text) == "string" then
    return { type = "result", text = response.text }
  end
end

---@param response table
---@return { type: "models", models: string[] }?
local function models_of(response)
  if vim.islist(response) and vim.iter(response):all(function(model)
    return type(model) == "string"
  end) then
    return { type = "models", models = response }
  end
end

---@type { process: vim.SystemObj, cancelled: boolean }?
local current

function M.running()
  return current ~= nil
end

--- Kills the running sidecar. Its outcome becomes a cancel, whatever it printed or exited with.
--- A timeout kill is vim.system's own and never sets `cancelled`.
function M.cancel()
  if current and not current.cancelled then
    current.cancelled = true
    current.process:kill("sigterm")
  end
end

--- Runs `request` and calls `on_done` on the main loop with the outcome. One request at a time:
--- callers check `running()` first.
---@param request table
---@param opts { timeout_ms: number }
---@param on_done fun(outcome: nvimpi.Outcome)
function M.run(request, opts, on_done)
  assert(not current, "nvimpi: a request is already running")
  local problem = node_problem()
  if problem then
    on_done({ type = "error", message = problem })
    return
  end
  local system_opts = { stdin = vim.json.encode(request) .. "\n", text = true, timeout = opts.timeout_ms }
  local ok, process = pcall(vim.system, M.command, system_opts, function(obj)
    vim.schedule(function()
      local cancelled = current and current.cancelled
      current = nil
      on_done(cancelled and { type = "cancel" } or outcome_of(obj, opts.timeout_ms, result_of))
    end)
  end)
  if not ok then
    on_done({ type = "error", message = "nvimpi: could not start the sidecar: " .. tostring(process) })
    return
  end
  current = { process = process, cancelled = false }
end

---@param response table
---@return { type: "source", source: "auth.json"|"env"|"none"|"unknown" }?
local function source_of(response)
  if response.type == "source" and vim.list_contains({ "auth.json", "env", "none", "unknown" }, response.source) then
    return { type = "source", source = response.source }
  end
end

--- Runs the sidecar with `args` instead of a request and waits for it. Independent of `run()`.
---@param args string[]
---@param accept fun(response: table): table?
---@return table
local function query(args, accept)
  local problem = node_problem()
  if problem then
    return { type = "error", message = problem }
  end
  local command = vim.list_extend(vim.list_extend({}, M.command), args)
  local ok, process = pcall(vim.system, command, { text = true, timeout = LIST_TIMEOUT_MS })
  if not ok then
    return { type = "error", message = "nvimpi: could not start the sidecar: " .. tostring(process) }
  end
  return outcome_of(process:wait(), LIST_TIMEOUT_MS, accept)
end

--- The models the user can pick, from `--list-models`. Blocks until the sidecar exits:
--- it is quick, and completion needs the answer synchronously.
---@param provider_ids string[] providers with a setup() key: ids only, never the keys
---@return { type: "models", models: string[] } | { type: "error"|"crash"|"timeout", message: string }
function M.list_models(provider_ids)
  return query({ "--list-models", unpack(provider_ids) }, models_of)
end

--- Which source covers `provider` when there is no setup() key, from `--credential-source`.
--- Blocks until the sidecar exits. Never runs key commands or prints a key.
---@param provider string
---@return { type: "source", source: "auth.json"|"env"|"none"|"unknown" } | { type: "error"|"crash"|"timeout", message: string }
function M.credential_source(provider)
  return query({ "--credential-source", provider }, source_of)
end

return M
