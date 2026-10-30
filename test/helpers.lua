-- Shared setup for the Lua tests: a fresh buffer, stubbed vim.ui.input and vim.notify,
-- and the sidecar swapped for test/fake_sidecar.sh through the runner's internal field.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local H = {}

H.request_file = vim.fn.tempname()

---@class helpers.State
---@field prompts string[] prompts shown by vim.ui.input
---@field notes { msg: string, level: integer, opts: table? }[] vim.notify calls

---@type helpers.State
H.state = { prompts = {}, notes = {} }

function H.eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\n  actual: %s"):format(what or "not equal", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- Fresh buffer with `lines`, a set model, and a fake sidecar answering `response` (a table encoded as JSON).
--- `sleep` (seconds) delays the response, to observe a running request.
---@param opts { lines: string[], instruction?: string?, response?: table, model?: string|false, filetype?: string, sleep?: number }
function H.reset(opts)
  H.cancel_running()
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.cmd("let &undolevels = &undolevels") -- the user's own edits end before the request

  local model = opts.model == nil and "faux/m1" or opts.model or nil
  require("nvimpi").setup({ model = model })
  require("nvimpi.runner").command = { "sh", root .. "/test/fake_sidecar.sh" }
  vim.env.NVIMPI_FAKE_REQUEST = H.request_file
  vim.env.NVIMPI_FAKE_RESPONSE = vim.json.encode(opts.response or { type = "result", text = "" })
  vim.env.NVIMPI_FAKE_SLEEP = opts.sleep and tostring(opts.sleep) or nil
  vim.fn.delete(H.request_file)

  H.state = { prompts = {}, notes = {} }
  vim.ui.input = function(input_opts, on_confirm)
    table.insert(H.state.prompts, input_opts.prompt)
    on_confirm(opts.instruction)
  end
  vim.notify = function(msg, level, notify_opts)
    table.insert(H.state.notes, { msg = msg, level = level, opts = notify_opts })
  end
  return buf
end

--- Type `keys` (to make a selection), then run the action from a mapping, like a user would.
function H.run_action(keys)
  vim.keymap.set({ "n", "x" }, "<Plug>(nvimpi-test)", require("nvimpi").prompt)
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<Plug>(nvimpi-test)"), "x", false)
end

function H.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

--- Wait until the buffer differs from `before`. Errors on timeout.
function H.wait_changed(before)
  local ok = vim.wait(5000, function()
    return not vim.deep_equal(before, H.lines())
  end, 10)
  assert(ok, "buffer did not change")
end

function H.wait_notified()
  assert(vim.wait(5000, function()
    return #H.state.notes > 0
  end, 10), "no notification")
end

--- The request line the fake sidecar received, decoded, or nil if it never ran.
function H.sent_request()
  if vim.fn.filereadable(H.request_file) == 0 then
    return nil
  end
  return vim.json.decode(table.concat(vim.fn.readfile(H.request_file), "\n"))
end

function H.running()
  return require("nvimpi").status() ~= ""
end

function H.wait_running()
  assert(vim.wait(5000, H.running, 10), "request did not start")
end

function H.wait_idle()
  assert(vim.wait(5000, function()
    return not H.running()
  end, 10), "request did not finish")
end

--- Press <C-c> in Normal mode like a user, so mappings apply.
function H.press_ctrl_c()
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "mx", false)
end

--- A request left running by a failed test must not leak into the next one.
function H.cancel_running()
  if H.running() then
    H.press_ctrl_c()
    H.wait_idle()
  end
end

--- Extmarks from any namespace in the current buffer: the moving highlight is one.
function H.extmarks()
  return vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {})
end

--- Give a sidecar that should not have been started time to show up anyway.
function H.settle()
  vim.wait(200, function()
    return false
  end)
end

return H
