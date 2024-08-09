-- simple testing:
-- open this file in neovim and run `:source %`
-- may break stuff in neovim, so you may need to restart

local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)

-- unload to get the latest changes
package.loaded["threading"] = nil
package.loaded["threading.util"] = nil
package.loaded["threading.thread"] = nil

local t = require("threading")

if _G.Thread then
  t.stop(_G.Thread)
end

local function tests()
  local function check(cond, msg)
    print(msg)
    assert(cond, msg)
  end

  check(vim.api.nvim_get_current_buf(), "Basic api call")

  check(vim.print("Hello, World!"), "Basic print call")
end

_G.Thread = t.start(tests)
