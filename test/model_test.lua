local h = require("helpers")
local eq = h.eq

local ERROR, WARN, INFO = vim.log.levels.ERROR, vim.log.levels.WARN, vim.log.levels.INFO
local REFUSED = "nvimpi: model is set in setup(): remove it there to use :NvimpiModel"
local NO_MODEL = "nvimpi: no model set. Run :NvimpiModel or set model in setup()"

local function note(msg, level)
  return { msg = msg, level = level, opts = { title = "nvimpi" } }
end

--- Rewrites the first line and waits for the request to end; returns the model it was sent with.
local function rewrite()
  h.state.notes = {}
  vim.fn.delete(h.request_file)
  h.run_action("ggV")
  assert(vim.wait(5000, function()
    return h.sent_request() ~= nil or #h.state.notes > 0
  end, 10), "request did not start")
  h.wait_idle()
  local sent = h.sent_request()
  return sent and sent.model
end

--- Stubs vim.ui.select to answer `choice`; returns the recorded calls.
local function stub_select(choice)
  local calls = {}
  vim.ui.select = function(items, opts, on_choice)
    table.insert(calls, { items = items, prompt = opts.prompt })
    on_choice(choice)
  end
  return calls
end

return {
  {
    ":NvimpiModel provider/id saves the model, and the next request uses it",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false })
      vim.cmd("NvimpiModel other/o1")
      eq('{"model":"other/o1"}', h.read_saved())
      eq({ note("nvimpi: model set to other/o1", INFO) }, h.state.notes)
      eq({ provider = "other", id = "o1" }, rewrite())
    end,
  },
  {
    ":NvimpiModel creates the data directory when it is missing",
    function()
      h.reset({ lines = { "a" }, model = false })
      eq(0, vim.fn.isdirectory(vim.fs.dirname(h.saved_model_file)))
      vim.cmd("NvimpiModel faux/m1")
      eq('{"model":"faux/m1"}', h.read_saved())
    end,
  },
  {
    "an id with more slashes is split at the first /",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false })
      vim.cmd("NvimpiModel openrouter/anthropic/claude")
      eq({ provider = "openrouter", id = "anthropic/claude" }, rewrite())
    end,
  },
  {
    ":NvimpiModel with an argument that is not provider/id is an error and saves nothing",
    function()
      h.reset({ lines = { "a" }, model = false })
      vim.cmd("NvimpiModel nope")
      eq({ note("nvimpi: expected provider/id, got nope", ERROR) }, h.state.notes)
      eq(nil, h.read_saved())
    end,
  },
  {
    "nvimpi.json edited outside Neovim takes effect on the next request",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false, saved = '{"model":"faux/m1"}' })
      eq({ provider = "faux", id = "m1" }, rewrite())
      h.write_saved('{"model":"other/o2"}')
      eq({ provider = "other", id = "o2" }, rewrite())
    end,
  },
  {
    "setup()'s model wins over nvimpi.json",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = "faux/m1", saved = '{"model":"other/o2"}' })
      eq({ provider = "faux", id = "m1" }, rewrite())
    end,
  },
  {
    ":NvimpiModel refuses when setup() sets model, with or without an argument",
    function()
      h.reset({ lines = { "a" }, model = "faux/m1" })
      local calls = stub_select("other/o1")
      vim.cmd("NvimpiModel other/o1")
      vim.cmd("NvimpiModel")
      eq({ note(REFUSED, ERROR), note(REFUSED, ERROR) }, h.state.notes)
      eq(nil, h.read_saved())
      eq({}, calls, "no picker")
      eq(nil, h.list_args(), "the sidecar never ran")
    end,
  },
  {
    ":NvimpiModel with no argument picks from the listed models and saves the choice",
    function()
      h.reset({ lines = { "a" }, model = false, models = { "faux/m1", "other/o1" } })
      local calls = stub_select("other/o1")
      vim.cmd("NvimpiModel")
      eq({ { items = { "faux/m1", "other/o1" }, prompt = "nvimpi model" } }, calls)
      eq('{"model":"other/o1"}', h.read_saved())
    end,
  },
  {
    "the list gets the api_keys provider ids, never the keys, and key functions are not called",
    function()
      local calls = 0
      local keys = {
        zeta = "fake-zeta-key",
        alpha = function()
          calls = calls + 1
          return "fake-alpha-key"
        end,
      }
      h.reset({ lines = { "a" }, model = false, models = { "alpha/a1" }, api_keys = keys })
      stub_select(nil)
      vim.cmd("NvimpiModel")
      eq({ "alpha", "zeta" }, h.list_args())
      eq(0, calls)
    end,
  },
  {
    "cancelling the picker saves nothing",
    function()
      h.reset({ lines = { "a" }, model = false, models = { "faux/m1" }, saved = '{"model":"other/o1"}' })
      stub_select(nil)
      vim.cmd("NvimpiModel")
      eq('{"model":"other/o1"}', h.read_saved())
      eq({}, h.state.notes)
    end,
  },
  {
    ":NvimpiModel says so when no provider has credentials, instead of an empty picker",
    function()
      h.reset({ lines = { "a" }, model = false, models = {} })
      local calls = stub_select(nil)
      vim.cmd("NvimpiModel")
      eq({}, calls)
      eq({
        note("nvimpi: no provider has credentials: log in with pi, set a provider's API key env var, or set api_keys in setup()", ERROR),
      }, h.state.notes)
    end,
  },
  {
    "a list error from the sidecar is shown as is",
    function()
      local message = "cannot read pi credentials from /x/auth.json: bad"
      h.reset({ lines = { "a" }, model = false, models = vim.json.encode({ type = "error", code = "provider", message = message }) })
      local calls = stub_select(nil)
      vim.cmd("NvimpiModel")
      eq({}, calls)
      eq({ note(message, ERROR) }, h.state.notes)
    end,
  },
  {
    "tab completion offers the listed models matching the typed prefix",
    function()
      h.reset({ lines = { "a" }, model = false, models = { "faux/m1", "other/o1", "other/o2" } })
      eq({ "other/o1", "other/o2" }, vim.fn.getcompletion("NvimpiModel oth", "cmdline"))
    end,
  },
  {
    "an invalid nvimpi.json is treated as unset and warns once",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false, saved = "{ not json" })
      eq(nil, rewrite())
      eq({ note(("nvimpi: ignoring %s: not valid JSON"):format(h.saved_model_file), WARN), note(NO_MODEL, ERROR) }, h.state.notes)
      eq(nil, rewrite())
      eq({ note(NO_MODEL, ERROR) }, h.state.notes, "no second warning")
    end,
  },
  {
    "nvimpi.json without a model string is invalid",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false, saved = '{"model":3}' })
      eq(nil, rewrite())
      eq(note(('nvimpi: ignoring %s: expected {"model":"provider/id"}'):format(h.saved_model_file), WARN), h.state.notes[1])
    end,
  },
  {
    "no nvimpi.json is unset without a warning",
    function()
      h.reset({ lines = { "a" }, instruction = "x", model = false })
      eq(nil, rewrite())
      eq({ note(NO_MODEL, ERROR) }, h.state.notes)
    end,
  },
  {
    "current() reports the model and where it came from",
    function()
      local model = require("nvimpi.model")
      h.reset({ lines = { "a" }, model = false })
      eq(nil, model.current())
      h.write_saved('{"model":"other/o1"}')
      eq({ model = "other/o1", source = "nvimpi.json" }, model.current())
      h.reset({ lines = { "a" }, model = "faux/m1", saved = '{"model":"other/o1"}' })
      eq({ model = "faux/m1", source = "setup()" }, model.current())
    end,
  },
}
