local h = require("helpers")
local eq = h.eq

local function undo_restores(original)
  vim.cmd("silent undo")
  eq(original, h.lines(), "one undo restores the original text")
end

return {
  {
    "Insert with nothing selected puts a one-line reply mid-line at the cursor, in one undo step",
    function()
      local original = { "local x = 1", "foo(bar)", "return x" }
      h.reset({ lines = original, instruction = "add arg", response = { type = "result", text = "a, " } })
      h.run_action("2gg0fb")
      h.wait_changed(original)

      eq({ "local x = 1", "foo(a, bar)", "return x" }, h.lines())
      eq({ "Insert 2:5❯ " }, h.state.prompts)
      eq({
        mode = "insert",
        instruction = "add arg",
        before = "local x = 1\nfoo(",
        selection = "",
        after = "bar)\nreturn x\n",
        filetype = "lua",
        model = { provider = "faux", id = "m1" },
      }, h.sent_request())
      eq({}, h.state.notes, "success shows no notification")
      undo_restores(original)
    end,
  },
  {
    "a multi-line Insert continues from the cursor and the rest of the line follows the last inserted line",
    function()
      local original = { "foo(bar)", "end" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "a,\n  b,\n  " } })
      h.run_action("gg0fb")
      h.wait_changed(original)

      eq({ "foo(a,", "  b,", "  bar)", "end" }, h.lines())
      undo_restores(original)
    end,
  },
  {
    "Insert at the start of an empty line",
    function()
      local original = { "a", "", "b" }
      h.reset({ lines = original, instruction = "x", response = { type = "result", text = "one\ntwo" } })
      h.run_action("2gg")
      h.wait_changed(original)

      eq({ "Insert 2:1❯ " }, h.state.prompts)
      local sent = h.sent_request()
      eq("a\n", sent.before)
      eq("\nb\n", sent.after)
      eq({ "a", "one", "two", "b" }, h.lines())
      undo_restores(original)
    end,
  },
  {
    "an empty Insert reply leaves the buffer unchanged and adds no undo step",
    function()
      local original = { "foo(bar)" }
      local buf = h.reset({ lines = original, instruction = "x", response = { type = "result", text = "" } })
      local tick = vim.b[buf].changedtick
      local undo_seq = vim.fn.undotree().seq_last
      h.run_action("gg0fb")
      assert(vim.wait(5000, function()
        return h.sent_request() ~= nil
      end, 10), "sidecar never ran")
      h.settle()

      eq(original, h.lines())
      eq(tick, vim.b[buf].changedtick, "no change")
      eq(undo_seq, vim.fn.undotree().seq_last, "no undo step")
      eq({}, h.state.notes)
    end,
  },
}
