-- Lua test runner: nvim --headless --clean -l test/run.lua [file_pattern]
-- Each test/*_test.lua file returns a list of { name, fn }. A test fails when fn errors.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/test/?.lua;" .. package.path

local pattern = _G.arg[1] or "*"
local total, failed = 0, 0
for _, file in ipairs(vim.fn.glob(root .. "/test/" .. pattern .. "_test.lua", false, true)) do
  for _, case in ipairs(dofile(file)) do
    total = total + 1
    local ok, err = xpcall(case[2], debug.traceback)
    if ok then
      io.stdout:write("ok    ", case[1], "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL  ", case[1], "\n", err, "\n")
    end
  end
end

io.stdout:write(("\n%d tests, %d failed\n"):format(total, failed))
os.exit(failed == 0 and total > 0 and 0 or 1)
