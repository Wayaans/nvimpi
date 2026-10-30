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
---@param opts { lines: string[], instruction?: string?, response?: table, model?: string|false, filetype?: string }
function H.reset(opts)
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

--- Give a sidecar that should not have been started time to show up anyway.
function H.settle()
  vim.wait(200, function()
    return false
  end)
end

return H
