# nvimpi

Neovim plugin for refining and refactoring the visual selection with AI, powered by [pi](https://github.com/earendil-works) through a Node sidecar.

Status: early development.

## Requirements

- Neovim 0.12+
- Node.js

## Install

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/Wayaans/nvimpi" })
require("nvimpi").setup()
```

Run `:checkhealth nvimpi` to verify the setup.
