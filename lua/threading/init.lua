local util = require("threading.util")

local M = {}

local uv = vim.uv

---@alias uv_thread userdata

---@class ThreadingThread
---@field thread uv_thread
---@field ctrl_read_pipe uv_pipe_t
---@field ctrl_write_pipe uv_pipe_t

---@class VimFunction
---@field functions string[]
---@field args any[]

---run vim function based on data
---@param data VimFunction
local function handle_vim(data)
  local fn = vim.iter(data.functions):fold(vim, function(acc, v)
    return acc and acc[v] or nil
  end)

  if fn then
    return fn(unpack(data.args))
  end
end

---return on_control
---@param ctrl_write_pipe uv_pipe_t
---@return function(err: string, data: string)
local function get_on_control(ctrl_write_pipe)
  return function(err, data)
    util.debug("m", err, data)

    if data == nil then
      util.debug("Thread closed control")
    elseif data then
      local ok, data_table = pcall(vim.mpack.decode, data)

      if not ok or type(data_table) ~= "table" then
        print("Failed to decode data: ", data)
        return
      end

      if data_table.type == "vim" then
        vim.schedule(function()
          -- TODO handle error
          local result = handle_vim(data_table)

          ctrl_write_pipe:write(vim.mpack.encode({ type = "vim_response", result = result }))
        end)
      end
    end
  end
end

---returns config for thread
---@return table
local function get_config()
  local vim_types = {}

  for k, v in pairs(vim) do
    vim_types[k] = type(v)
  end

  return {
    vim_types = vim_types,
  }
end

---start a new thread
---@param callback function
---@param ... any
---@return ThreadingThread
function M.start(callback, ...)
  local ctrl_to_main = uv.pipe({ nonblock = true }, { nonblock = true })
  local ctrl_to_thread = uv.pipe({ nonblock = true }, { nonblock = true })

  local ctrl_read_pipe = util.open_fd(ctrl_to_main.read)
  local ctrl_write_pipe = util.open_fd(ctrl_to_thread.write)

  ctrl_read_pipe:read_start(get_on_control(ctrl_write_pipe))

  local cb_string = string.dump(callback)
  local config = vim.mpack.encode(get_config())

  local thread = uv.new_thread(function(...)
    require("threading.thread").run(...)
  end, ctrl_to_main.write, ctrl_to_thread.read, cb_string, config, ...)

  return {
    thread = thread,
    ctrl_read_pipe = ctrl_read_pipe,
    ctrl_write_pipe = ctrl_write_pipe,
  }
end

---stop a thread by sending a stop message
---@param thread ThreadingThread
function M.stop(thread)
  thread.ctrl_read_pipe:close()
  thread.ctrl_write_pipe:close()
end

return M
