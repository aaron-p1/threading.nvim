-- open this file in neovim and run `:source %`
-- may break stuff in neovim, so you may need to restart

local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)

-- unload to get the latest changes
package.loaded["threading"] = nil
package.loaded["threading.util"] = nil
package.loaded["threading.thread"] = nil

local t = require("threading")
local tutil = require("threading.util")

tutil.print_debug = false

if _G.Thread then
  t.stop(_G.Thread)
end

print("------------ Starting tests")

local function tests()
  ---@param name string
  ---@param cb function
  local function check(name, cb)
    print("----- Testing: ", name)
    cb()
    print("----- PASSED")
  end

  check("Simple functions", function()
    vim.schedule(function()
      print("Simple scheduling")
    end)

    vim.print("-- If no 'Simple scheduling' is printed, then this test failed")
  end)

  check("Functions with simple upvalues", function()
    local upvalue = "first"

    vim.schedule(function()
      print("Upvalue is:", upvalue)
      print("Now changing to: second")
      upvalue = "second"

      vim.defer_fn(function()
        print("Upvalue should be third:", upvalue)
      end, 10)
    end)

    vim.schedule(function()
      print("Upvalue should be second:", upvalue)
      print("Now changing to: third")
      upvalue = "third"
    end)

    vim.uv.sleep(20)

    vim.print("-- The messages above must be right to pass")
  end)

  check("Functions as upvalues", function()
    local upvalue = "first"

    local fn_upvalue = function(prefix)
      print(prefix, upvalue)
    end

    vim.schedule(function()
      fn_upvalue("Calling from upvalue function and other upvalue should be first:")
    end)

    vim.schedule(function()
      upvalue = "second"
      fn_upvalue("Calling from upvalue function and other upvalue should be second:")
    end)

    local a = 10

    local function fn_recursive(prefix, to)
      if a <= to then
        return
      end

      print(prefix, a)

      a = a - 1
      return fn_recursive(prefix, to)
    end

    vim.schedule(function()
      fn_recursive("First recursive call counting from 10 to 5:", 5)
    end)

    vim.schedule(function()
      fn_recursive("Second recursive call counting from 5 to 0:", 0)
    end)

    vim.uv.sleep(10)

    vim.print("-- The messages above must be right to pass")
  end)

  vim.stop_thread()
end

_G.Thread = t.start(tests, nil, { debug = tutil.print_debug })
