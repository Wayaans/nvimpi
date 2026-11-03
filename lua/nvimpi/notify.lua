-- Every message nvimpi shows goes through here, titled nvimpi.
---@param message string
---@param level integer a vim.log.levels value
return function(message, level)
  vim.notify(message, level, { title = "nvimpi" })
end
