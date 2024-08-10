local util = require("threading.util")

local M = {}

local uv = vim.uv

_G._vim = vim

function _vim.stop_thread()
  util.debug("Stopping thread")
  uv.stop()
end

local function get_call_to_main(ctrl_write_pipe, keys)
  return function(...)
    util.debug("Calling", keys, ...)

    util.write_to_pipe(ctrl_write_pipe, {
      type = "vim",
      kind = "call",
      keys = keys,
      args = { ... }
    })

    return coroutine.yield()
  end
end

local function get_data_from_main(ctrl_write_pipe, keys)
  util.debug("Getting", keys)

  util.write_to_pipe(ctrl_write_pipe, {
    type = "vim",
    kind = "get",
    keys = keys
  })

  return coroutine.yield()
end

local function assign_data_to_main(ctrl_write_pipe, keys, value)
  util.debug("Assigning", keys, value)

  util.write_to_pipe(ctrl_write_pipe, {
    type = "vim",
    kind = "set",
    keys = keys,
    value = value
  })

  return coroutine.yield()
end

---@type boolean -- if true, the thread is currently executing neovim internal functions
local is_in_interal = false

---when getting an old value, set is_in_interal because neovim calls `vim.*`
---@param old table
---@param key string|number
---@return any
local function get_old_key(old, key)
  is_in_interal = true
  local result = old[key]
  is_in_interal = false

  return result
end

local function get_override_table(ctrl_write_pipe, old, types, prev_keys)
  old = old or {}
  prev_keys = prev_keys or {}

  local result = {}

  setmetatable(result, {
    __index = function(_, key)
      if is_in_interal then
        return old[key]
      end

      if types[key] == "function" then
        local old_value = get_old_key(old, key)
        if old_value then
          return old_value
        end

        return get_call_to_main(ctrl_write_pipe, util.fappend(prev_keys, key))
      elseif types[key] == "table" and types.subtypes[key] then
        local old_value = get_old_key(old, key)

        return get_override_table(
          ctrl_write_pipe,
          old_value,
          types.subtypes[key],
          util.fappend(prev_keys, key)
        )
      else
        local old_value = get_old_key(old, key)
        if old_value then
          return old_value
        end

        return get_data_from_main(ctrl_write_pipe, util.fappend(prev_keys, key))
      end
    end,
    __newindex = function(_, key, value)
      if is_in_interal then
        old[key] = value
        return
      end

      local keys = util.fappend(prev_keys, key)

      return assign_data_to_main(ctrl_write_pipe, keys, value)
    end,
    __call = function(_, ...)
      if is_in_interal then
        return old(...)
      end

      return get_call_to_main(ctrl_write_pipe, prev_keys)(...)
    end,
  })

  return result
end

---sets up the global `vim` variable
---@param ctrl_write_pipe uv_pipe_t
---@param config table
local function init_vim(ctrl_write_pipe, config)
  _G.vim = get_override_table(ctrl_write_pipe, _vim, config.vim_types)
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
---@return fun(err: string, data: string)
local function get_on_control(co)
  return util.dechunk_pipe_msg(
    function(data)
      if data.type == "vim_response" then
        util.debug("Received vim_response:", data.result)
        resume(co, data.result)
      end
    end,
    function(err)
      print("Error in control pipe in thread: ", err)
    end,
    function()
      _vim.stop_thread()
    end
  )
end

---entry point for the thread
---@param write_fd integer
---@param read_fd integer
---@param cb_string string
---@param config string
---@param arg_str string
---@param arg_len integer
function M.run(write_fd, read_fd, cb_string, config, arg_str, arg_len)
  util.debug("Starting thread")

  local config_table = _vim.mpack.decode(config)

  local args = _vim.mpack.decode(arg_str)

  local ctrl_write_pipe = util.open_fd(write_fd)
  local ctrl_read_pipe = util.open_fd(read_fd)

  init_vim(ctrl_write_pipe, config_table)

  local co = coroutine.create(function()
    local fn, err = loadstring(cb_string)
    assert(fn, "Failed to load string: " .. (err or ""))
    fn(unpack(args, 1, arg_len))
  end)

  ctrl_read_pipe:read_start(get_on_control(co))

  resume(co)

  uv.run()
end

return M
