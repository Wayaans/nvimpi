local h = require("helpers")
local eq = h.eq

local WARN = vim.log.levels.WARN

local function only_warn(msg)
  eq({ { msg = msg, level = WARN, opts = { title = "nvimpi" } } }, h.state.notes)
end

--- Start a request answered with `text` after a short sleep, and wait until it runs.
local function start(lines, keys, text)
  local buf = h.reset({ lines = lines, instruction = "fix it", response = { type = "result", text = text }, sleep = 0.3 })
  h.run_action(keys)
  h.wait_running()
  return buf
end

--- Edit like a user: the buffer stays editable while the request runs.
local function set_lines(first, last, replacement)
  vim.api.nvim_buf_set_lines(0, first, last, true, replacement)
end

--- Wait for the request to end with a dropped result.
local function wait_dropped()
  h.wait_idle()
  h.wait_notified()
end

--- The next prompt after a dropped result shows the Instruction again.
local function next_prompt_refilled()
  h.run_action("gg")
  eq("fix it", h.state.defaults[#h.state.defaults], "the Instruction is prefilled")
end

return {
  {
    "Rewrite: an edit inside the target drops the result with a WARN and keeps the user's text",
    function()
      start({ "keep", "foo bar baz", "end" }, "2gg0wve", "QUX")
      vim.api.nvim_buf_set_text(0, 1, 5, 1, 6, { "A" })
      wait_dropped()

      eq({ "keep", "foo bAr baz", "end" }, h.lines())
      only_warn("nvimpi: text changed, result discarded")
      next_prompt_refilled()
    end,
  },
  {
    "Rewrite: lines added and removed above the target still apply to the right text",
    function()
      start({ "a", "b", "target 1", "target 2", "c" }, "3ggVj", "new")
      set_lines(0, 2, { "x" }) -- remove two lines above, add one
      set_lines(0, 0, { "top 1", "top 2" })
      vim.cmd("let &undolevels = &undolevels")
      local before = h.lines()
      h.wait_changed(before)

      eq({ "top 1", "top 2", "x", "new", "c" }, h.lines())
      eq({}, h.state.notes)
      vim.cmd("silent undo")
      eq(before, h.lines(), "one undo restores the user's text")
    end,
  },
  {
    "Rewrite: edits next to a charwise selection on the same line are outside and still apply",
    function()
      start({ "foo bar baz" }, "0wve", "QUX")
      vim.api.nvim_buf_set_text(0, 0, 0, 0, 3, { "f" }) -- shorten the text before it
      vim.api.nvim_buf_set_text(0, 0, 5, 0, 5, { "!" }) -- type right after it
      vim.api.nvim_buf_set_text(0, 0, 2, 0, 2, { "<" }) -- type right before it
      local before = h.lines()
      h.wait_changed(before)

      eq({ "f <QUX! baz" }, h.lines())
      eq({}, h.state.notes)
    end,
  },
  {
    "Rewrite: typing at the start of a Visual-line target changes the target",
    function()
      start({ "a", "line", "b" }, "2ggV", "new")
      vim.api.nvim_buf_set_text(0, 1, 0, 1, 0, { "x" })
      wait_dropped()

      eq({ "a", "xline", "b" }, h.lines())
      only_warn("nvimpi: text changed, result discarded")
    end,
  },
  {
    "Rewrite: deleting the whole target drops the result",
    function()
      start({ "a", "line", "b" }, "2ggV", "new")
      set_lines(1, 2, {})
      wait_dropped()

      eq({ "a", "b" }, h.lines())
      only_warn("nvimpi: text changed, result discarded")
    end,
  },
  {
    "Rewrite: closing the buffer drops the result with a WARN and no error",
    function()
      local buf = start({ "a", "b" }, "ggV", "new")
      vim.cmd("bwipeout! " .. buf)
      wait_dropped()

      only_warn("nvimpi: buffer closed, result discarded")
      next_prompt_refilled()
    end,
  },
  {
    "Rewrite: unloading a hidden buffer drops the result with a WARN and no error",
    function()
      local buf = start({ "a", "b", "c" }, "ggVj", "new")
      vim.bo[buf].bufhidden = ""
      vim.cmd("enew!")
      vim.cmd("bunload! " .. buf)
      vim.wait(250, function() -- let the moving highlight tick on the unloaded buffer
        return false
      end)
      wait_dropped()

      only_warn("nvimpi: buffer closed, result discarded")
      vim.cmd("bwipeout! " .. buf)
    end,
  },
  {
    "Insert: an edit on the cursor line drops the result with a WARN",
    function()
      start({ "x", "foo(bar)" }, "2gg0fb", "a, ")
      vim.api.nvim_buf_set_text(0, 1, 7, 1, 8, { "]" })
      wait_dropped()

      eq({ "x", "foo(bar]" }, h.lines())
      only_warn("nvimpi: text changed, result discarded")
      next_prompt_refilled()
    end,
  },
  {
    "Insert: lines added and removed around the cursor line still insert at the cursor spot",
    function()
      start({ "a", "b", "foo(bar)", "c" }, "3gg0fb", "a, ")
      set_lines(0, 2, { "one", "two", "three" })
      set_lines(4, 5, {}) -- remove the line below too
      local before = h.lines()
      h.wait_changed(before)

      eq({ "one", "two", "three", "foo(a, bar)" }, h.lines())
      eq({}, h.state.notes)
    end,
  },
  {
    "Insert: closing the buffer drops the result with a WARN and no error",
    function()
      local buf = start({ "foo(bar)" }, "gg0fb", "a, ")
      vim.cmd("bwipeout! " .. buf)
      wait_dropped()

      only_warn("nvimpi: buffer closed, result discarded")
      next_prompt_refilled()
    end,
  },
}
