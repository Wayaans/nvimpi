if vim.g.loaded_nvimpi then
  return
end
vim.g.loaded_nvimpi = true

vim.api.nvim_create_user_command("NvimpiModel", function(cmd)
  require("nvimpi.model").command(cmd.args)
end, {
  nargs = "?",
  desc = "nvimpi: set the model (provider/id), or pick one",
  complete = function(arglead)
    return require("nvimpi.model").complete(arglead)
  end,
})
