-- Runner: spawns one sidecar per request, writes the request line, closes stdin,
-- and turns the single stdout line into an outcome.
local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- Internal, not a setup() option: the sidecar command. Tests swap in a fake script.
M.command = { "node", root .. "/sidecar/dist/sidecar.mjs" }

---@alias nvimpi.Outcome { type: "result", text: string } | { type: "error", message: string }

---@param obj vim.SystemCompleted
---@return nvimpi.Outcome
local function outcome_of(obj)
  local ok, response = pcall(vim.json.decode, (obj.stdout or ""):match("^[^\n]*"))
  if ok and type(response) == "table" then
    if response.type == "result" and type(response.text) == "string" then
      return { type = "result", text = response.text }
    elseif response.type == "error" and type(response.message) == "string" then
      return { type = "error", message = response.message }
    end
  end
  local how = obj.signal ~= 0 and ("signal %d"):format(obj.signal) or ("exit %d"):format(obj.code)
  return { type = "error", message = ("nvimpi: sidecar crashed (%s)"):format(how) }
end

--- Runs `request` and calls `on_done` on the main loop with the outcome.
---@param request table
---@param on_done fun(outcome: nvimpi.Outcome)
function M.run(request, on_done)
  local ok, err = pcall(vim.system, M.command, { stdin = vim.json.encode(request) .. "\n", text = true }, function(obj)
    vim.schedule(function()
      on_done(outcome_of(obj))
    end)
  end)
  if not ok then
    on_done({ type = "error", message = "nvimpi: could not start the sidecar: " .. tostring(err) })
  end
end

return M
