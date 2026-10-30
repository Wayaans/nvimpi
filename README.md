# nvimpi

A small Neovim plugin that rewrites the selected text with an AI model. Select text, type an Instruction, and the model's reply replaces the selection as one undo step. Requests go through [pi-durable](https://github.com/earendil-works/pi) in a bundled Node sidecar.

Status: early development.

## Requirements

- Neovim 0.12+
- Node.js 22.19+ on `PATH`

There is no `npm install` and there are no Lua dependencies: the sidecar is committed as one bundled file.

## Install

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/Wayaans/nvimpi" })
require("nvimpi").setup({ model = "anthropic/claude-sonnet-4-5" })
vim.keymap.set("x", "<leader>p", require("nvimpi").prompt, { desc = "nvimpi: Rewrite selection" })
```

`model` is `"provider/id"` using pi-ai's provider ids. It is split at the first `/`, so ids like `openrouter/anthropic/claude-sonnet-4-5` work. There is no default model: set one in `setup()` or with `:NvimpiModel`.

`timeout_ms` (a number, default `120000`) limits how long a request may run. After it the sidecar is killed and nvimpi reports `nvimpi: timed out after <n>s`. Raise it for slow local models: `setup({ model = "...", timeout_ms = 300000 })`.

### Choosing a model

Instead of `model` in `setup()`, you can pick one from Neovim:

- `:NvimpiModel provider/id` sets the model. `<Tab>` completes the ids.
- `:NvimpiModel` with no argument opens a picker (`vim.ui.select`) over the models of every provider you have credentials for: a pi login or key, a set environment variable, or an `api_keys` entry. If no provider has credentials, it says so instead.

The choice is saved to `stdpath("data")/nvimpi.json` as `{"model":"provider/id"}` and read again on every request, so a change made in another Neovim instance (or by editing the file) applies to the next request. If the file is unreadable or invalid, nvimpi warns once and treats the model as unset.

`model` in `setup()` always wins. While it is set, `:NvimpiModel` refuses with `model is set in setup(): remove it there to use :NvimpiModel`.

### Credentials

nvimpi looks for a key in this order, and the first source with an entry for the provider wins: `api_keys` in `setup()`, then pi's `auth.json`, then the provider's environment variable.

#### `api_keys` in setup()

Without pi, or to pick a key explicitly, set `api_keys`: a table from provider id to a key, or to a function that returns one. The recommended setup on macOS keeps the key in the Keychain and reads it when a request starts:

```lua
-- Store it once: security add-generic-password -a "$USER" -s nvimpi-anthropic -w
require("nvimpi").setup({
  model = "anthropic/claude-sonnet-4-5",
  api_keys = {
    anthropic = function()
      local result = vim.system({ "security", "find-generic-password", "-s", "nvimpi-anthropic", "-w" }, { text = true }):wait()
      assert(result.code == 0, "no nvimpi-anthropic item in the Keychain")
      return result.stdout
    end,
  },
})
```

A literal key works too:

```lua
require("nvimpi").setup({ model = "anthropic/claude-sonnet-4-5", api_keys = { anthropic = "sk-ant-..." } })
```

Do not commit a literal key: dotfiles often end up in a public repository. Prefer the Keychain function, or read the key from a file outside your dotfiles.

- Only the current model's provider is looked up, and its function runs once per request. The result is trimmed.
- If the function throws, or the key is empty or not a string, nvimpi reports `nvimpi: api_keys.<provider> failed: <reason>` and sends nothing.
- The key reaches the sidecar on stdin only, never in its arguments or environment. A key the provider rejects is reported (with the key shown as `***`), and nvimpi does not fall back to another source.

#### pi and environment variables

If you use [pi](https://github.com/earendil-works/pi), nvimpi reuses its logins with no extra setup. It reads pi's `auth.json` (`$PI_CODING_AGENT_DIR/auth.json`, or `~/.pi/agent/auth.json`):

- API keys work as in pi: a literal key, `$ENV` or `${ENV}`, or `!command` (run in `sh` with a 5 s timeout, once per request).
- Subscription logins (`/login` in pi) work while their token is valid. nvimpi never refreshes a token or writes the file, so when a login expires, open pi once to refresh it.
- An entry for the provider always wins. If it is broken (for example its command fails), nvimpi reports the error instead of trying anything else.

Without a pi entry for the provider, credentials come from the provider's environment variable, for example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. The variable must be set in the environment Neovim runs in.

## Usage

Select text (`v` or `V`), press your mapping, and type an Instruction at the `Rewrite 3,9❯` prompt. `<CR>` sends it. `<Esc>`, `<C-c>` or an empty Instruction closes the prompt without sending.

- A charwise selection replaces only the selected characters.
- A linewise selection replaces whole lines and keeps the line structure.
- An empty reply deletes the selection.
- One `u` undoes the change. Success shows no message, and any failure shows one error titled `nvimpi` and leaves the buffer untouched.
- After a failure, the next prompt opens with the failed Instruction filled in, so you can retry it or edit it.

While a request runs, a highlight moves down the target lines and the buffer stays editable. Nothing opens or takes focus. Only one request runs at a time.

- `<C-c>` in Normal mode cancels the request, silently and without touching the buffer. nvimpi maps `<C-c>` only while a request runs and restores your own mapping afterwards.
- `require("nvimpi").status()` returns a spinner and the elapsed time while a request runs, and an empty string otherwise. nvimpi never changes `'statusline'`; add it yourself:

```lua
vim.o.statusline = "%f %m%=%{v:lua.require'nvimpi'.status()} %l:%c"
```

The highlight uses the `NvimpiWorking` group, linked to `Visual` by default.

The model also sees up to 100 lines of Context above and below the selection, and the buffer's filetype.

## Troubleshooting

Run `:checkhealth nvimpi`. It checks Neovim, `node` (22.19 or newer on `PATH`), the bundled sidecar, the current model and where it comes from (`setup()` or `nvimpi.json`), and which credential source covers the model's provider (`api_keys` in setup(), pi's `auth.json`, or an environment variable). It never calls an `api_keys` function, runs an `auth.json` key command, or shows a key.

## Development

The sidecar is TypeScript in `sidecar/src`, bundled with esbuild into `sidecar/dist/sidecar.mjs`, which is committed. Rebuild it after changing the sidecar or its dependencies.

```sh
npm install          # dev only: pi-durable, pi-ai and esbuild
npm test             # sidecar handler, --list-models and --credential-source tests (node --test, pi-ai faux provider)
npm run build        # bundle sidecar/src into sidecar/dist/sidecar.mjs
npm run smoke        # run the bundle from an empty directory with no node_modules
npm run test:lua     # Lua tests in headless Neovim with a fake sidecar
```

`npm run test:lua` only needs `nvim` (it runs `nvim --headless --clean -l test/run.lua`). Pass a file name pattern to run one file: `nvim --headless --clean -l test/run.lua rewrite`.
