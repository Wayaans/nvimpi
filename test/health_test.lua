local h = require("helpers")
local eq = h.eq

--- Runs the health check with vim.health stubbed; returns { level, msg, advice } per reported item.
local function check()
  local report = {}
  local saved = {}
  for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    saved[level] = vim.health[level]
    vim.health[level] = function(msg, advice)
      table.insert(report, { level = level, msg = msg, advice = advice })
    end
  end
  local ok, err = pcall(require("nvimpi.health").check)
  for level, fn in pairs(saved) do
    vim.health[level] = fn
  end
  assert(ok, err)
  return report
end

--- The single item whose message contains `needle`.
local function item(report, needle)
  local found = vim.tbl_filter(function(entry)
    return entry.msg:find(needle, 1, true) ~= nil
  end, report)
  assert(#found == 1, ("expected one item with %q, got %s"):format(needle, vim.inspect(report)))
  return found[1]
end

local function text_of(report)
  return vim.inspect(report)
end

local function source(name)
  return { type = "source", source = name }
end

return {
  {
    "a working setup reports Neovim, node, the sidecar, the model and its credentials as OK",
    function()
      h.reset({ lines = { "" }, model = "faux/m1", source = source("env") })
      local report = check()
      eq("ok", item(report, "Neovim").level)
      eq("ok", item(report, "node v22.19.0").level)
      eq("ok", item(report, "sidecar").level)
      eq({ level = "ok", msg = "model faux/m1 (from setup())" }, item(report, "model faux/m1"))
      eq({ level = "ok", msg = "faux credentials: an environment variable" }, item(report, "credentials"))
      eq({ "--credential-source", "faux" }, h.list_args())
    end,
  },
  {
    "node missing or too old is an ERROR; the check re-reads the version, so an upgrade shows and applies",
    function()
      h.reset({ lines = { "a" }, instruction = "x", response = { type = "result", text = "b" } })
      vim.env.NVIMPI_FAKE_NODE_VERSION = "v20.1.0"
      eq("error", item(check(), "node v20.1.0").level)
      vim.env.NVIMPI_FAKE_NODE_VERSION = "v22.19.0" -- the user upgrades node, as the error advises
      eq("ok", item(check(), "node v22.19.0").level)
      h.run_action("ggV")
      h.wait_changed({ "a" })
      eq({}, h.state.notes, "the request uses the version the check found")
      eq(2, h.node_runs(), "the request reuses it without running node again")

      h.reset({ lines = { "" } })
      require("nvimpi.runner").node = "/nonexistent/node"
      local report = check()
      eq("error", item(report, "node not found").level)
      assert(text_of(report):find("credentials not checked", 1, true), "credentials are skipped without node")
      eq(nil, h.list_args())
    end,
  },
  {
    "a missing sidecar bundle is an ERROR",
    function()
      h.reset({ lines = { "" } })
      require("nvimpi.runner").sidecar = "/nonexistent/sidecar.mjs"
      eq("error", item(check(), "/nonexistent/sidecar.mjs").level)
    end,
  },
  {
    "the saved model shows its source; no model WARNs with a hint to run :NvimpiModel",
    function()
      h.reset({ lines = { "" }, model = false, saved = '{"model":"other/o1"}', source = source("auth.json") })
      local report = check()
      eq("ok", item(report, "model other/o1 (from nvimpi.json)").level)
      eq({ level = "ok", msg = "other credentials: pi's auth.json" }, item(report, "credentials"))

      h.reset({ lines = { "" }, model = false, saved = "{ broken" })
      report = check()
      local missing = item(report, "no model set")
      eq("warn", missing.level)
      assert(table.concat(missing.advice):find(":NvimpiModel", 1, true), "hint names :NvimpiModel")
      eq("warn", item(report, "not valid JSON").level)
      eq(nil, h.list_args())
    end,
  },
  {
    "no credentials, an unknown provider, or a sidecar error give an ERROR with a hint",
    function()
      h.reset({ lines = { "" }, model = "faux/m1", source = source("none") })
      local none = item(check(), "no credentials for faux")
      eq("error", none.level)
      assert(table.concat(none.advice):find("api_keys.faux", 1, true), "hint names the setup key")

      h.reset({ lines = { "" }, model = "nobody/x", source = source("unknown") })
      eq("error", item(check(), "unknown provider nobody").level)

      h.reset({ lines = { "" }, model = "faux/m1", source = { type = "error", code = "provider", message = "cannot read pi credentials from /a: not valid JSON" } })
      eq("error", item(check(), "cannot read pi credentials from /a").level)
    end,
  },
  {
    "a setup key wins, without calling it, and no key value appears in the report",
    function()
      local called = false
      h.reset({
        lines = { "" },
        model = "faux/m1",
        api_keys = {
          faux = function()
            called = true
            return "fn-secret-value"
          end,
        },
      })
      local report = check()
      eq({ level = "ok", msg = "faux credentials: api_keys.faux in setup()" }, item(report, "credentials"))
      eq(false, called)
      eq(nil, h.list_args())
      assert(not text_of(report):find("fn-secret-value", 1, true), "function key not shown")

      h.reset({ lines = { "" }, model = "faux/m1", api_keys = { faux = "  str-secret-value " } })
      report = check()
      eq("ok", item(report, "credentials").level)
      assert(not text_of(report):find("str-secret-value", 1, true), "string key not shown")
    end,
  },
  {
    "an empty or wrongly typed setup key is an ERROR",
    function()
      h.reset({ lines = { "" }, model = "faux/m1", api_keys = { faux = "  " } })
      eq("error", item(check(), "api_keys.faux is empty").level)

      h.reset({ lines = { "" }, model = "faux/m1", api_keys = { faux = 42 } })
      eq("error", item(check(), "api_keys.faux must be a string or a function, got number").level)
    end,
  },
}
