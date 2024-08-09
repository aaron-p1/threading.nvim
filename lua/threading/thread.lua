local util = require("threading.util")

local M = {}

local uv = vim.uv

local function get_call_to_main(ctrl_write_pipe, functions)
  return function(...)
    util.debug("Calling", functions, ...)

    ctrl_write_pipe:write(vim.mpack.encode({
      type = "vim",
      functions = functions,
      args = { ... }
    }))

    return coroutine.yield()
  end
end

---sets up the global `vim` variable
---@param ctrl_write_pipe uv_pipe_t
---@param config table
local function init_vim(ctrl_write_pipe, config)
  local old_vim = vim

  local api = {}
  setmetatable(api, {
    __index = function(_, fn)
      return get_call_to_main(ctrl_write_pipe, { "api", fn })
    end
  })

  local new_vim = {}
  setmetatable(new_vim, {
    __index = function(_, key)
      if key == "api" then
        return api
      end

      if old_vim[key] then
        return old_vim[key]
      end

      if config.vim_types[key] == "function" then
        return get_call_to_main(ctrl_write_pipe, { key })
      end

      assert(false, "Not implemented: " .. key)
    end,
  })

  _G.vim = new_vim
end

---resumes a coroutine and throws an error if it fails
---@param ... any
local function resume(...)
  local ok, err = coroutine.resume(...)

  if not ok then
    error(err)
  end
end

---return on_control
---@param co thread
---@return function(err: string, data: string)
local function get_on_control(co)
  return function(err, data)
    util.debug("t", err, data)

    if not data then
      util.debug("Stopping")
      uv.stop()
    else
      local ok, data_table = pcall(vim.mpack.decode, data)

      if not ok or type(data_table) ~= "table" then
        print("Failed to decode data: ", data)
        return
      end

      if data_table.type == "vim_response" then
        resume(co, data_table.result)
      end
    end
  end
end

---entry point for the thread
---@param write_fd integer
---@param read_fd integer
---@param cb_string string
---@param config string
---@param ... any -- TODO handle table
function M.run(write_fd, read_fd, cb_string, config, ...)
  local config_table = vim.mpack.decode(config)

  local args = { ... }

  local ctrl_write_pipe = util.open_fd(write_fd)
  local ctrl_read_pipe = util.open_fd(read_fd)

  init_vim(ctrl_write_pipe, config_table)

  local co = coroutine.create(function()
    local fn, err = loadstring(cb_string)
    assert(fn, "Failed to load string: " .. (err or ""))
    fn(unpack(args))
  end)

  ctrl_read_pipe:read_start(get_on_control(co))

  resume(co)

  uv.run()
end

return M
