local M = {}

---@class nvimpi.Config
local defaults = {}

---@type nvimpi.Config
M.config = vim.deepcopy(defaults)

---@param opts? nvimpi.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

return M
