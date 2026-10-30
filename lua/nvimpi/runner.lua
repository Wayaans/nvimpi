-- Runner: checks node, spawns one sidecar per request, writes the request line, closes stdin,
-- and turns the single stdout line (or its absence) into an outcome.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- Internal, not a setup() option: the sidecar command. Tests swap in a fake script.
M.command = { "node", root .. "/sidecar/dist/sidecar.mjs" }

--- Internal: the `node` the version check looks for on PATH. Tests swap in a fake script.
M.node = "node"

--- Internal: `node --version` output, cached for the session after the first request.
---@type string?
M.node_version = nil

local STDERR_TAIL_LINES = 10
local SIGTERM = 15

---@alias nvimpi.Outcome
---| { type: "result", text: string }
---| { type: "error", message: string } a sidecar error line, or a failure before spawning
---| { type: "crash", message: string }
---| { type: "timeout", message: string }

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

--- nil when node is usable, otherwise the message to show.
---@return string?
local function node_problem()
  local found = "none"
  if vim.fn.executable(M.node) == 1 then
    if M.node_version == nil then
      local ok, obj = pcall(function()
        return vim.system({ M.node, "--version" }, { text = true }):wait(5000)
      end)
      M.node_version = ok and vim.trim(obj.stdout or "") or ""
    end
    if supported(M.node_version) then
      return nil
    end
    found = M.node_version ~= "" and M.node_version or "none"
  end
  return ("nvimpi: Node 22.19+ required (found %s). Run :checkhealth nvimpi"):format(found)
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

---@param obj vim.SystemCompleted
---@param timeout_ms number
---@return nvimpi.Outcome
local function outcome_of(obj, timeout_ms)
  -- vim.system reports its own timeout as code 124 after sending TERM.
  if obj.code == 124 and obj.signal == SIGTERM then
    return { type = "timeout", message = ("nvimpi: timed out after %gs"):format(timeout_ms / 1000) }
  end
  local ok, response = pcall(vim.json.decode, (obj.stdout or ""):match("^[^\n]*"))
  if ok and type(response) == "table" then
    if response.type == "result" and type(response.text) == "string" then
      return { type = "result", text = response.text }
    elseif response.type == "error" and type(response.message) == "string" then
      return { type = "error", message = response.message }
    end
  end
  local how = obj.signal ~= 0 and ("signal %d"):format(obj.signal) or ("exit %d"):format(obj.code)
  return { type = "crash", message = ("nvimpi: sidecar crashed (%s)%s"):format(how, stderr_tail(obj.stderr)) }
end

--- Runs `request` and calls `on_done` on the main loop with the outcome.
---@param request table
---@param opts { timeout_ms: number }
---@param on_done fun(outcome: nvimpi.Outcome)
function M.run(request, opts, on_done)
  local problem = node_problem()
  if problem then
    on_done({ type = "error", message = problem })
    return
  end
  local system_opts = { stdin = vim.json.encode(request) .. "\n", text = true, timeout = opts.timeout_ms }
  local ok, err = pcall(vim.system, M.command, system_opts, function(obj)
    vim.schedule(function()
      on_done(outcome_of(obj, opts.timeout_ms))
    end)
  end)
  if not ok then
    on_done({ type = "error", message = "nvimpi: could not start the sidecar: " .. tostring(err) })
  end
end

return M
