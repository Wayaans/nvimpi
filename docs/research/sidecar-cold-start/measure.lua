-- Usage: nvim --headless -l measure.lua <node_args...>
local N = 20
local function epoch_ms() local s, us = vim.uv.gettimeofday(); return s * 1000 + us / 1000 end
local function stats(xs)
  table.sort(xs)
  local function p(q) return xs[math.max(1, math.ceil(q * #xs))] end
  return string.format("min %6.1f  median %6.1f  p90 %6.1f  max %6.1f", xs[1], p(0.5), p(0.9), xs[#xs])
end

local cold = { ready = {}, sent = {}, result = {} }
local function one_cold()
  local t0 = epoch_ms()
  local marks, buf = {}, ""
  local proc
  proc = vim.system({ "node", "/tmp/nvimpi-coldstart/run/sidecar.mjs" }, {
    stdin = true, env = { MOCK_URL = "http://127.0.0.1:8787", ANTHROPIC_API_KEY = "dummy" },
    stdout = function(_, data)
      if not data then return end
      buf = buf .. data
      for line in buf:gmatch("([^\n]*)\n") do
        local msg = vim.json.decode(line)
        local now = epoch_ms()
        if msg.type == "ready" then
          marks.ready = now - t0
          proc:write(vim.json.encode({ id = 1, text = "hello" }) .. "\n")
        elseif msg.type == "result" then
          marks.sent = tonumber(msg.text) - t0
          marks.result = now - t0
          proc:write(nil)
        else
          error(line)
        end
      end
      buf = buf:match("[^\n]*$")
    end,
  })
  proc:wait()
  return marks
end

local function warm()
  local t, buf, done = {}, "", nil
  local proc
  local function req(i) t.start = epoch_ms(); proc:write(vim.json.encode({ id = i, text = "hi" }) .. "\n") end
  local i = 0
  proc = vim.system({ "node", "/tmp/nvimpi-coldstart/run/sidecar.mjs" }, {
    stdin = true, env = { MOCK_URL = "http://127.0.0.1:8787", ANTHROPIC_API_KEY = "dummy" },
    stdout = function(_, data)
      if not data then return end
      buf = buf .. data
      for line in buf:gmatch("([^\n]*)\n") do
        local msg = vim.json.decode(line)
        if msg.type == "result" then
          table.insert(t, { sent = tonumber(msg.text) - t.start, result = epoch_ms() - t.start })
        end
        i = i + 1
        if i <= N then req(i) else proc:write(nil) end
      end
      buf = buf:match("[^\n]*$")
    end,
  })
  proc:wait()
  return t
end

local function bare_node()
  local xs = {}
  for _ = 1, N do
    local t0 = epoch_ms()
    vim.system({ "node", "-e", "" }):wait()
    table.insert(xs, epoch_ms() - t0)
  end
  return xs
end

one_cold() -- discard first (disk cache)
for _ = 1, N do
  local m = one_cold()
  table.insert(cold.ready, m.ready); table.insert(cold.sent, m.sent); table.insert(cold.result, m.result)
end
print("node " .. vim.trim(vim.system({ "node", "--version" }):wait().stdout) .. ", nvim " .. tostring(vim.version()) .. ", N=" .. N .. " (ms)")
print("bare `node -e ''` spawn+exit      " .. stats(bare_node()))
print("cold: spawn -> ready              " .. stats(cold.ready))
print("cold: spawn -> request at server  " .. stats(cold.sent))
print("cold: spawn -> result in Lua      " .. stats(cold.result))
local w = warm()
local ws, wr = {}, {}
for k = 2, #w do table.insert(ws, w[k].sent); table.insert(wr, w[k].result) end
print("warm: write -> request at server  " .. stats(ws))
print("warm: write -> result in Lua      " .. stats(wr))
