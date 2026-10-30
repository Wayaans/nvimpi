local h = require("helpers")
local eq = h.eq

local function numbered(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "l" .. i
  end
  return lines
end

--- Lines first..last, each with its newline, as the buffer stretch the request must reproduce.
local function stretch(lines, first, last)
  return table.concat(vim.list_slice(lines, first, last), "\n") .. "\n"
end

local function undo_restores(original)
  vim.cmd("silent undo")
  eq(original, h.lines(), "one undo restores the original text")
end

return {
  {
    "charwise Rewrite replaces only the selected characters, silently, in one undo step",
    function()
      local original = { "local x = foo(1, 2)", "return x" }
      h.reset({ lines = original, instruction = "rename", response = { type = "result", text = "a, b" } })
      h.run_action("gg0f1vf2")
      h.wait_changed(original)

      eq({ "local x = foo(a, b)", "return x" }, h.lines())
      eq({ "Rewrite 1,1❯ " }, h.state.prompts)
      eq({
        mode = "rewrite",
        instruction = "rename",
        before = "local x = foo(",
        selection = "1, 2",
        after = ")\nreturn x\n",
        filetype = "lua",
        model = { provider = "faux", id = "m1" },
      }, h.sent_request())
      eq({}, h.state.notes, "success shows no notification")
      undo_restores(original)
    end,
  },
  {
    "charwise Rewrite across lines with multibyte characters",
    function()
      local original = { "héllo wörld", "ünïcode line", "tail" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "W\nU" } })
      h.run_action("gg0fwvj0fï")
      h.wait_changed(original)

      local sent = h.sent_request()
      eq("héllo ", sent.before)
      eq("wörld\nünï", sent.selection)
      eq("code line\ntail\n", sent.after)
      eq({ "héllo W", "Ucode line", "tail" }, h.lines())
      undo_restores(original)
    end,
  },
  {
    "charwise selection to the end of the line keeps the newline",
    function()
      local original = { "one two", "three" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "2" } })
      h.run_action("gg0wv$")
      h.wait_changed(original)

      eq("two", h.sent_request().selection)
      eq({ "one 2", "three" }, h.lines())
    end,
  },
  {
    "linewise Rewrite replaces whole lines and keeps the line structure",
    function()
      local original = { "a", "b", "c", "d" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "B\nC\nX" } })
      h.run_action("ggjVj")
      h.wait_changed(original)

      local sent = h.sent_request()
      eq("a\n", sent.before)
      eq("b\nc", sent.selection)
      eq("\nd\n", sent.after)
      eq({ "Rewrite 2,3❯ " }, h.state.prompts)
      eq({ "a", "B", "C", "X", "d" }, h.lines())
      eq({}, h.state.notes)
      undo_restores(original)
    end,
  },
  {
    "an empty result deletes a charwise selection in one undo step",
    function()
      local original = { "keep DROP keep" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "" } })
      h.run_action("gg0fDvf ")
      h.wait_changed(original)

      eq({ "keep keep" }, h.lines())
      undo_restores(original)
    end,
  },
  {
    "an empty result deletes linewise-selected lines in one undo step",
    function()
      local original = { "a", "b", "c" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "" } })
      h.run_action("ggjV")
      h.wait_changed(original)

      eq({ "a", "c" }, h.lines())
      undo_restores(original)
    end,
  },
  {
    "Context is capped at 100 lines on each side",
    function()
      local original = numbered(300)
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "new" } })
      h.run_action("150GV")
      h.wait_changed(original)

      local sent = h.sent_request()
      eq(stretch(original, 50, 149), sent.before)
      eq("l150", sent.selection)
      eq("\n" .. stretch(original, 151, 250), sent.after)
    end,
  },
  {
    "charwise Context is 100 full lines plus the partial first and last lines",
    function()
      local original = numbered(300)
      original[150] = "abcdef"
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "X" } })
      h.run_action("150G0lvl")
      h.wait_changed(original)

      local sent = h.sent_request()
      eq(stretch(original, 50, 149) .. "a", sent.before)
      eq("bc", sent.selection)
      eq("def\n" .. stretch(original, 151, 250), sent.after)
    end,
  },
  {
    "Context is shorter near the edges of the buffer",
    function()
      local original = numbered(10)
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "new" } })
      h.run_action("3GV")
      h.wait_changed(original)
      eq("l1\nl2\n", h.sent_request().before)
      eq("\n" .. stretch(original, 4, 10), h.sent_request().after)

      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "new" } })
      h.run_action("GV")
      h.wait_changed(original)
      eq(stretch(original, 1, 9), h.sent_request().before)
      eq("\n", h.sent_request().after)
    end,
  },
  {
    "<Esc> or <C-c> (no input) closes the prompt without spawning",
    function()
      local original = { "a", "b" }
      h.reset({ lines = original, instruction = nil })
      h.run_action("ggV")
      h.settle()
      eq(1, #h.state.prompts)
      eq(nil, h.sent_request(), "no sidecar started")
      eq(original, h.lines())
      eq({}, h.state.notes)
    end,
  },
  {
    "an empty Instruction closes the prompt without spawning",
    function()
      local original = { "a", "b" }
      h.reset({ lines = original, instruction = "" })
      h.run_action("ggV")
      h.settle()
      eq(nil, h.sent_request(), "no sidecar started")
      eq(original, h.lines())
      eq({}, h.state.notes)
    end,
  },
  {
    "no model set: one ERROR and no sidecar",
    function()
      local original = { "a" }
      h.reset({ lines = original, instruction = "x", model = false })
      h.run_action("ggV")
      h.settle()
      eq({
        {
          msg = "nvimpi: no model set. Run :NvimpiModel or set model in setup()",
          level = vim.log.levels.ERROR,
          opts = { title = "nvimpi" },
        },
      }, h.state.notes)
      eq(nil, h.sent_request(), "no sidecar started")
      eq(original, h.lines())
    end,
  },
  {
    "the model is split at the first slash",
    function()
      local original = { "a" }
      h.reset({ lines = original, instruction = "x", model = "openrouter/anthropic/claude", response = { type = "result", text = "b" } })
      h.run_action("ggV")
      h.wait_changed(original)
      eq({ provider = "openrouter", id = "anthropic/claude" }, h.sent_request().model)
    end,
  },
  {
    "an error line shows its message unchanged as one ERROR and leaves the buffer",
    function()
      local original = { "a" }
      local message = "no credentials for faux: log in with pi, or set its API key env var"
      h.reset({ lines = original, instruction = "x", response = { type = "error", code = "not_configured", message = message } })
      h.run_action("ggV")
      h.wait_notified()
      eq({ { msg = message, level = vim.log.levels.ERROR, opts = { title = "nvimpi" } } }, h.state.notes)
      eq(original, h.lines())
    end,
  },
}
