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

print("------------ Starting tests")

local function tests(first, second, third)
  local function check(cond, msg)
    print(msg .. ":", cond)
    assert(cond, msg)
    print("--- Passed")
  end

  check(first == "first", "First argument is 'first'")
  check(second == nil, "Second argument is nil")
  check(third.test == "table", "Third argument is table")

  check(vim.api.nvim_get_current_buf(), "Read current bufnum")

  check(vim.api.nvim_win_get_buf(0), "Read bufnum from current window")

  check(vim.print("Hello, World!"), "vim.print")

  check(vim.o.filetype, "Read vim.o.filetype")

  check((function ()
    vim.o.number = not vim.o.number
    return string.format("Set number to %s", vim.o.number)
  end)(), "Set vim.o.number")
  vim.o.number = not vim.o.number

  check((function ()
    local result = vim.fn.getcwd()
    return string.format("Read cwd as %s", result)
  end)(), "Read vim.fn.getcwd()")

  -- vim.cmd seems to work but echo does not print anything
  check((function ()
    vim.cmd.tabnext()
    return true
  end)(), "Run vim.cmd.tabnext()")

  vim.uv.sleep(200)

  check((function ()
    vim.cmd("tabprevious")
    return true
  end)(), "Run vim.cmd('tabprevious')")

  vim.stop_thread()
end

_G.Thread = t.start(tests, "first", nil, { test = "table" })
