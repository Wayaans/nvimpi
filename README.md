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

`model` is `"provider/id"` using pi-ai's provider ids. It is split at the first `/`, so ids like `openrouter/anthropic/claude-sonnet-4-5` work. There is no default model.

Credentials come from the provider's environment variable, for example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. The variable must be set in the environment Neovim runs in.

## Usage

Select text (`v` or `V`), press your mapping, and type an Instruction at the `Rewrite 3,9❯` prompt. `<CR>` sends it. `<Esc>`, `<C-c>` or an empty Instruction closes the prompt without sending.

- A charwise selection replaces only the selected characters.
- A linewise selection replaces whole lines and keeps the line structure.
- An empty reply deletes the selection.
- One `u` undoes the change. Success shows no message, and any failure shows one error titled `nvimpi`.

The model also sees up to 100 lines of Context above and below the selection, and the buffer's filetype.

Run `:checkhealth nvimpi` to verify the setup.

## Development

The sidecar is TypeScript in `sidecar/src`, bundled with esbuild into `sidecar/dist/sidecar.mjs`, which is committed. Rebuild it after changing the sidecar or its dependencies.

```sh
npm install          # dev only: pi-durable, pi-ai and esbuild
npm test             # sidecar handler tests (node --test, pi-ai faux provider)
npm run build        # bundle sidecar/src into sidecar/dist/sidecar.mjs
npm run smoke        # run the bundle from an empty directory with no node_modules
npm run test:lua     # Lua tests in headless Neovim with a fake sidecar
```

`npm run test:lua` only needs `nvim` (it runs `nvim --headless --clean -l test/run.lua`). Pass a file name pattern to run one file: `nvim --headless --clean -l test/run.lua rewrite`.
