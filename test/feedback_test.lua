local h = require("helpers")
local eq = h.eq
local nvimpi = require("nvimpi")

local LINES = { "one", "two", "three", "four" }

--- The global Normal-mode <C-c> mapping, or nil.
local function ctrl_c_map()
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.lhs == "<C-C>" then
      return map
    end
  end
end

--- Rows the moving highlight lit over about `ms` milliseconds (several ticks).
local function lit_rows(ms)
  local ns = vim.api.nvim_get_namespaces()["nvimpi.feedback"]
  local rows = {}
  vim.wait(ms, function()
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
      rows[mark[2]] = true
    end
    return false
  end, 20)
  return vim.tbl_keys(rows)
end

return {
  {
    "status() is empty when idle and shows progress while a request runs",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "TWO" }, sleep = 0.5 })
      eq("", nvimpi.status(), "idle before")
      h.run_action("jV")
      h.wait_running()
      assert(nvimpi.status():match("%ds"), "status shows elapsed seconds: " .. nvimpi.status())
      h.wait_changed(LINES)
      eq("", nvimpi.status(), "idle after")
    end,
  },
  {
    "the highlight shows on the target while running and is cleared after success",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B\nC" }, sleep = 0.5 })
      h.run_action("jVj")
      h.wait_running()
      local marks = h.extmarks()
      assert(#marks > 0, "a highlight is shown")
      assert(marks[1][2] >= 1 and marks[1][2] <= 2, "highlight is on a target line, got row " .. marks[1][2])
      h.wait_changed(LINES)
      eq({}, h.extmarks(), "highlight cleared")
      eq({ "one", "B", "C", "four" }, h.lines())
    end,
  },
  {
    "the highlight is cleared after a failure",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "error", message = "nvimpi: boom" }, sleep = 0.3 })
      h.run_action("V")
      h.wait_running()
      assert(#h.extmarks() > 0, "a highlight is shown")
      h.wait_notified()
      h.wait_idle()
      eq({}, h.extmarks(), "highlight cleared")
      eq("nvimpi: boom", h.state.notes[1].msg)
    end,
  },
  {
    "<C-c> cancels silently: sidecar killed, buffer and undo history untouched, highlight cleared",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "CHANGED" }, sleep = 5 })
      local undo_before = vim.fn.undotree().seq_last
      local started = vim.uv.now()
      h.run_action("jV")
      h.wait_running()
      assert(vim.wait(2000, function()
        return h.sent_request() ~= nil
      end, 10), "the request was sent")
      h.press_ctrl_c()
      h.wait_idle()
      assert(vim.uv.now() - started < 3000, "the sidecar was killed rather than waited for")
      h.settle()
      eq(LINES, h.lines(), "buffer untouched")
      eq(undo_before, vim.fn.undotree().seq_last, "undo history untouched")
      eq({}, h.state.notes, "a cancel shows no notification")
      eq({}, h.extmarks(), "highlight cleared")
    end,
  },
  {
    "<C-c> is mapped only while a request runs",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B" }, sleep = 0.5 })
      eq(nil, ctrl_c_map(), "not mapped before")
      h.run_action("jV")
      h.wait_running()
      assert(ctrl_c_map(), "mapped while running")
      h.wait_changed(LINES)
      eq(nil, ctrl_c_map(), "not mapped after")
    end,
  },
  {
    "the user's own <C-c> mapping is restored after the request",
    function()
      vim.keymap.set("n", "<C-c>", "<Cmd>let g:user_ctrl_c = 1<CR>", { desc = "mine" })
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B" }, sleep = 5 })
      h.run_action("jV")
      h.wait_running()
      h.press_ctrl_c()
      h.wait_idle()
      eq(nil, vim.g.user_ctrl_c, "the user's mapping did not run during the request")
      local map = ctrl_c_map()
      eq("mine", map and map.desc, "the user's mapping is back")
      h.press_ctrl_c()
      eq(1, vim.g.user_ctrl_c, "and it still works")
      vim.keymap.del("n", "<C-c>")
      vim.g.user_ctrl_c = nil
    end,
  },
  {
    "a second prompt while a request runs is refused with a WARN",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B" }, sleep = 5 })
      h.run_action("jV")
      h.wait_running()
      h.run_action("V")
      eq({ "Rewrite 2,2❯ " }, h.state.prompts, "no second prompt opened")
      eq(1, #h.state.notes)
      eq("nvimpi: a request is already running (<C-c> cancels it)", h.state.notes[1].msg)
      eq(vim.log.levels.WARN, h.state.notes[1].level)
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false) -- the refused selection stays
      h.press_ctrl_c()
      h.wait_idle()
      eq(LINES, h.lines())
    end,
  },
  {
    "after a cancel the next request runs normally",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B" }, sleep = 5 })
      h.run_action("jV")
      h.wait_running()
      h.press_ctrl_c()
      h.wait_idle()
      vim.env.NVIMPI_FAKE_SLEEP = nil
      h.run_action("ggjV")
      h.wait_changed(LINES)
      eq({ "one", "B", "three", "four" }, h.lines())
      eq({}, h.state.notes)
    end,
  },
  {
    "the highlight follows the target when lines are added or removed above it",
    function()
      h.reset({ lines = LINES, instruction = "x", response = { type = "result", text = "B\nC" }, sleep = 1.5 })
      h.run_action("jVj")
      h.wait_running()
      vim.api.nvim_buf_set_lines(0, 0, 0, true, { "a", "b", "c" })
      for _, row in ipairs(lit_rows(400)) do
        assert(row == 4 or row == 5, "lit row " .. row .. " is on the moved target (rows 4-5)")
      end
      vim.api.nvim_buf_set_lines(0, 0, 4, true, {})
      for _, row in ipairs(lit_rows(400)) do
        assert(row == 0 or row == 1, "lit row " .. row .. " is on the moved target (rows 0-1)")
      end
      h.wait_changed({ "two", "three", "four" })
      eq({ "B", "C", "four" }, h.lines())
    end,
  },
}
