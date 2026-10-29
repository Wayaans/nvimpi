local M = {}

function M.check()
  vim.health.start("nvimpi")

  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12+")
  else
    vim.health.error("nvimpi requires Neovim 0.12+")
  end

  if vim.fn.executable("node") == 1 then
    vim.health.ok("node found: " .. vim.trim(vim.fn.system({ "node", "--version" })))
  else
    vim.health.error("node not found in PATH")
  end
end

return M
