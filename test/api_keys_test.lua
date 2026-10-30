local h = require("helpers")
local eq = h.eq

local ERROR = vim.log.levels.ERROR

--- Rewrite the first line with `api_keys` in setup, and wait for the request to end.
local function rewrite_with(api_keys)
  h.reset({ lines = { "a" }, instruction = "x", response = { type = "result", text = "b" }, api_keys = api_keys })
  h.run_action("ggV")
  assert(vim.wait(5000, function()
    return #h.state.notes > 0 or h.lines()[1] == "b"
  end, 10), "request did not finish")
end

local function only_error(msg)
  eq({ { msg = msg, level = ERROR, opts = { title = "nvimpi" } } }, h.state.notes)
  eq(nil, h.sent_request(), "the sidecar never ran")
  eq({ "a" }, h.lines())
end

return {
  {
    "a string key reaches the sidecar trimmed",
    function()
      rewrite_with({ faux = "  fake-string-key\n" })
      eq("fake-string-key", h.sent_request().api_key)
    end,
  },
  {
    "a function key is called when the request starts and its result is trimmed",
    function()
      local calls = 0
      rewrite_with({
        faux = function()
          calls = calls + 1
          return "fake-fn-key\n"
        end,
      })
      eq(1, calls)
      eq("fake-fn-key", h.sent_request().api_key)
    end,
  },
  {
    "only the current provider's key is resolved and sent",
    function()
      local other_calls = 0
      rewrite_with({
        other = function()
          other_calls = other_calls + 1
          return "fake-other-key"
        end,
      })
      eq(0, other_calls, "another provider's function is never called")
      eq(nil, h.sent_request().api_key, "api_key is left out without an entry")
    end,
  },
  {
    "no api_keys leaves api_key out",
    function()
      rewrite_with(nil)
      eq(nil, h.sent_request().api_key)
    end,
  },
  {
    "a throwing key function fails without spawning and refills the Instruction",
    function()
      rewrite_with({
        faux = function()
          error("keychain locked", 0)
        end,
      })
      only_error("nvimpi: api_keys.faux failed: keychain locked")
      eq("x", require("nvimpi").failed_instruction)
    end,
  },
  {
    "a key function returning only whitespace fails without spawning",
    function()
      rewrite_with({
        faux = function()
          return " \n"
        end,
      })
      only_error("nvimpi: api_keys.faux failed: the key is empty")
    end,
  },
  {
    "a key function returning a non-string fails without spawning",
    function()
      rewrite_with({
        faux = function()
          return 42
        end,
      })
      only_error("nvimpi: api_keys.faux failed: expected a string, got number")
    end,
  },
  {
    "an empty string key fails without spawning",
    function()
      rewrite_with({ faux = "" })
      only_error("nvimpi: api_keys.faux failed: the key is empty")
    end,
  },
  {
    "setup rejects api_keys that is not a table",
    function()
      eq(false, (pcall(require("nvimpi").setup, { api_keys = "fake-key" })))
      require("nvimpi").setup({})
    end,
  },
}
