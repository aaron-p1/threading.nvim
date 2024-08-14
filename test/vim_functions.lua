-- simple testing:
-- open this file in neovim and run `:source %`
-- may break stuff in neovim, so you may need to restart

local _cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(_cwd)

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

local function tests(first, second, third)
  ---@param name string
  ---@param cb function
  local function check(name, cb)
    print("----- Testing: ", name)
    cb()
    print("----- PASSED")
  end

  local function tostr(...)
    local args = { ... }

    local strings = vim.tbl_map(function(v)
      if type(v) == "string" or type(v) == "number" then
        return v
      else
        vim.inspect(v)
      end
    end, args)

    return table.concat(strings, " ")
  end

  check("Parameters", function()
    assert(first == "first", tostr("First argument is not 'first':", first))
    assert(second == nil, tostr("Second argument is not nil:", second))
    assert(third.test == "table", tostr("Third argument is not a table with [test] == 'table':", third))
  end)

  check("Api call with not args and serializable output", function()
    local bufnr = vim.api.nvim_get_current_buf()

    assert(type(bufnr) == "number", tostr("Bufnr is not a number:", bufnr))
  end)

  check("Api call with args and serializable output", function()
    assert(vim.api.nvim_win_get_buf(0), "Read bufnum from current window")
  end)

  check("Simple vim functions with args", function()
    vim.print("Hello, World!")
    print("-- If no 'Hello, World!' printed, then vim.print is not working. (Might be further up or down in messages)")
  end)

  check("vim.o", function()
    local ft = vim.o.filetype
    assert(ft == "lua", tostr("vim.o.filetype is not 'lua':", ft))

    local number = vim.o.number
    vim.o.number = not vim.o.number
    assert(vim.o.number ~= number, tostr("vim.o.number cannot be set:", vim.o.number))
    vim.o.number = not vim.o.number
  end)

  check("vim.fn", function()
    local cwd = vim.fn.getcwd()
    assert(type(cwd) == "string", tostr("vim.fn.getcwd() cannot be called:", cwd))
  end)

  check("vim.cmd", function()
    if #vim.api.nvim_list_tabpages() > 1 then
      local tabpagenr = vim.fn.tabpagenr()
      assert(type(tabpagenr) == "number", tostr("vim.fn.tabpagenr() cannot be called:", tabpagenr))

      vim.cmd.tabnext()
      assert(vim.fn.tabpagenr() ~= tabpagenr, tostr("vim.cmd.tabnext() cannot be called"))
      vim.cmd("tabprevious")
      assert(vim.fn.tabpagenr() == tabpagenr, tostr("vim.cmd('tabprevious') cannot be called"))
    else
      print("nothing tested because only one tab exists")
    end
  end)
end

_G.Thread = t.start(tests, { "first", nil, { test = "table" } }, { debug = tutil.print_debug })
