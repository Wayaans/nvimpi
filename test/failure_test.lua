local h = require("helpers")
local eq = h.eq

local ERROR = vim.log.levels.ERROR

--- The one ERROR notification titled nvimpi, as the user sees it.
local function only_error(msg)
  eq({ { msg = msg, level = ERROR, opts = { title = "nvimpi" } } }, h.state.notes)
end

--- Run a Visual-line Rewrite of the first line and wait for its notification.
local function fail_once()
  h.run_action("ggV")
  h.wait_notified()
end

--- Run another Rewrite in the same session (no reset), answered with `response`.
local function rewrite_again(response, instruction)
  vim.env.NVIMPI_FAKE_RESPONSE = vim.json.encode(response)
  vim.env.NVIMPI_FAKE_EXIT = nil
  h.state.notes = {}
  vim.ui.input = function(input_opts, on_confirm)
    table.insert(h.state.prompts, input_opts.prompt)
    table.insert(h.state.defaults, input_opts.default or false)
    on_confirm(instruction)
  end
  local before = h.lines()
  h.run_action("ggV")
  if response.type == "result" then
    h.wait_changed(before)
  else
    h.wait_notified()
  end
end

return {
  {
    "a sidecar sleeping past timeout_ms is reported as a timeout and leaves the buffer",
    function()
      local original = { "a", "b" }
      h.reset({ lines = original, instruction = "x", timeout_ms = 300, sleep = 5, response = { type = "result", text = "z" } })
      local undo_steps = vim.fn.undotree().seq_last
      fail_once()
      only_error("nvimpi: timed out after 0.3s")
      eq(original, h.lines())
      eq(undo_steps, vim.fn.undotree().seq_last, "no undo step was added")
    end,
  },
  {
    "a sidecar exiting without output is a crash with the exit code and the stderr tail",
    function()
      local stderr = {}
      for i = 1, 12 do
        stderr[i] = "err" .. i
      end
      local original = { "a" }
      h.reset({ lines = original, instruction = "x", response = false, exit = 3, stderr = table.concat(stderr, "\n") })
      fail_once()
      only_error("nvimpi: sidecar crashed (exit 3)\n" .. table.concat(stderr, "\n", 3, 12))
      eq(original, h.lines())
    end,
  },
  {
    "a sidecar printing junk is a crash, even with exit 0",
    function()
      local original = { "a" }
      h.reset({ lines = original, instruction = "x", response = "not json", stderr = "boom" })
      fail_once()
      only_error("nvimpi: sidecar crashed (exit 0)\nboom")
      eq(original, h.lines())
    end,
  },
  {
    "a well-formed line of the wrong shape is a crash, with no tail when stderr is empty",
    function()
      h.reset({ lines = { "a" }, instruction = "x", response = { type = "result" } })
      fail_once()
      only_error("nvimpi: sidecar crashed (exit 0)")
    end,
  },
  {
    "a missing node is reported before spawning",
    function()
      local original = { "a" }
      h.reset({ lines = original, instruction = "x" })
      require("nvimpi.runner").node = "nvimpi-no-such-node"
      fail_once()
      only_error("nvimpi: Node 22.19+ required (found none). Run :checkhealth nvimpi")
      h.settle()
      eq(nil, h.sent_request(), "the sidecar never ran")
      eq(original, h.lines())
    end,
  },
  {
    "a too-old node is reported before spawning",
    function()
      h.reset({ lines = { "a" }, instruction = "x" })
      vim.env.NVIMPI_FAKE_NODE_VERSION = "v22.18.9"
      fail_once()
      only_error("nvimpi: Node 22.19+ required (found v22.18.9). Run :checkhealth nvimpi")
      h.settle()
      eq(nil, h.sent_request(), "the sidecar never ran")
    end,
  },
  {
    "node --version runs once per session",
    function()
      h.reset({ lines = { "a" }, instruction = "x", response = { type = "result", text = "b" } })
      h.run_action("ggV")
      h.wait_changed({ "a" })
      rewrite_again({ type = "result", text = "c" }, "y")
      eq({ "c" }, h.lines())
      eq(1, h.node_runs())
    end,
  },
  {
    "a newer node major passes the check",
    function()
      h.reset({ lines = { "a" }, instruction = "x", response = { type = "result", text = "b" } })
      vim.env.NVIMPI_FAKE_NODE_VERSION = "v24.0.0"
      h.run_action("ggV")
      h.wait_changed({ "a" })
      eq({}, h.state.notes)
    end,
  },
  {
    "after a failure the next prompt is prefilled with the failed Instruction",
    function()
      h.reset({ lines = { "a" }, instruction = "make it better", response = { type = "error", message = "nvimpi: nope" } })
      fail_once()
      eq({ false }, h.state.defaults, "the first prompt starts empty")
      rewrite_again({ type = "result", text = "b" }, "make it better")
      eq({ false, "make it better" }, h.state.defaults)
    end,
  },
  {
    "after a timeout the next prompt is prefilled",
    function()
      h.reset({ lines = { "a" }, instruction = "slow one", timeout_ms = 200, sleep = 5 })
      fail_once()
      vim.env.NVIMPI_FAKE_SLEEP = nil
      rewrite_again({ type = "result", text = "b" }, "x")
      eq({ false, "slow one" }, h.state.defaults)
    end,
  },
  {
    "after a success the next prompt starts empty",
    function()
      h.reset({ lines = { "a" }, instruction = "first", response = { type = "error", message = "nvimpi: nope" } })
      fail_once()
      rewrite_again({ type = "result", text = "b" }, "first")
      rewrite_again({ type = "result", text = "c" }, "second")
      eq({ false, "first", false }, h.state.defaults)
    end,
  },
}
