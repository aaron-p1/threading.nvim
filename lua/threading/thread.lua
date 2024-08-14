-- this file is not executed in the main thread
-- global variables are not shared between threads

local util = require("threading.util")

local M = {}

local uv = vim.uv

_G._vim = vim
_G._require = require

local config = {}

---@type table<integer, thread> active coroutines in this thread. The key is the id
local active_coroutines = {}
local co_id_counter = 0

---@type table<integer, function> functions that were sent to the main thread. The key is the id
local sent_functions = {}
local function_id_counter = 0

function _vim.stop_thread()
  util.debug("Stopping thread")
  uv.stop()
end

---make data serializable and saves original
---@param data any
---@return any
local function to_serializable(data)
  local sdata
  sdata, sent_functions, function_id_counter = util.to_serializable(
    data,
    function_id_counter,
    sent_functions,
    config.proxy_functions
  )
  return sdata
end

---resumes a coroutine and checks for errors
local function resume_check_err(...)
  local ok, err = coroutine.resume(...)

  if not ok then
    error(err)
  end
end

---resumes a coroutine and deletes dead coroutines from `running_coroutines`
---@param co_id thread
---@param ... any
local function resume(co_id, ...)
  for id, co in pairs(active_coroutines) do
    if coroutine.status(co) == "dead" then
      active_coroutines[id] = nil
    end
  end

  local co = active_coroutines[co_id]

  if not co then
    return
  end

  resume_check_err(co, ...)
end


---writes to control pipe
---@param ctrl_write_pipe uv_pipe_t
---@param waiting_for_response boolean
---@param data table
---@return nil
local function send_ctrl_msg(ctrl_write_pipe, waiting_for_response, data)
  if waiting_for_response then
    local found_co_id
    local running_co = coroutine.running()
    for id, co in pairs(active_coroutines) do
      if co == running_co then
        found_co_id = id
        break
      end
    end

    assert(found_co_id, "Could not find coroutine")

    data.___co_id = found_co_id
  end

  util.write_to_pipe(ctrl_write_pipe, data)
end

---returns a function that calls a vim function on the main thread
---@param ctrl_write_pipe uv_pipe_t
---@param keys string[]
---@return function
local function get_call_to_main(ctrl_write_pipe, keys)
  return function(...)
    util.debug("Calling", keys, ...)

    send_ctrl_msg(ctrl_write_pipe, true, {
      type = "vim",
      kind = "call",
      keys = keys,
      args = to_serializable({ ... })
    })

    return coroutine.yield()
  end
end

---get a vim variable from the main thread
---@param ctrl_write_pipe uv_pipe_t
---@param keys string[]
---@return any
local function get_data_from_main(ctrl_write_pipe, keys)
  util.debug("Getting", keys)

  -- TODO handle tables as keys (should be converted to "table: 0x...")
  send_ctrl_msg(ctrl_write_pipe, true, {
    type = "vim",
    kind = "get",
    keys = keys
  })

  return coroutine.yield()
end

---assigns a value to a vim variable on the main thread
---@param ctrl_write_pipe uv_pipe_t
---@param keys string[]
---@param value any
---@return any
local function assign_data_to_main(ctrl_write_pipe, keys, value)
  util.debug("Assigning", keys, value)

  send_ctrl_msg(ctrl_write_pipe, true, {
    type = "vim",
    kind = "set",
    keys = keys,
    value = to_serializable(value)
  })

  -- TODO why wait for response
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

---returns a metatable that proxies unknown keys of `old` to the main thread
---@param ctrl_write_pipe uv_pipe_t
---@param old table?
---@param types table
---@param prev_keys string[]?
---@return table
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

        if type(old_value) == "function" then
          return old_value
        end

        return get_override_table(
          ctrl_write_pipe,
          old_value,
          types[key] == nil and {} or types.subtypes[key],
          util.fappend(prev_keys, key)
        )
      elseif types[key] == nil then
        -- TODO make all of this dynamic when implementing sendable metatables
        local value_keys = { "o" }
        local function_keys = { "fn", "cmd" }

        if _vim.tbl_contains(value_keys, prev_keys[1]) then
          return get_data_from_main(ctrl_write_pipe, util.fappend(prev_keys, key))
        elseif _vim.tbl_contains(function_keys, prev_keys[1]) then
          return get_override_table(ctrl_write_pipe, get_old_key(old, key), {}, util.fappend(prev_keys, key))
        end

        local old_value = get_old_key(old, key)
        if old_value then
          return old_value
        end

        error("Unknown key: " .. table.concat(prev_keys, ".") .. "." .. key)
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

      local mt = getmetatable(old)
      if mt and type(mt.__call) == "function" then
        return old(...)
      end

      return get_call_to_main(ctrl_write_pipe, prev_keys)(...)
    end,
  })

  return result
end

---sets up the global variables
---@param ctrl_write_pipe uv_pipe_t
local function init_globals(ctrl_write_pipe)
  _G.vim = get_override_table(ctrl_write_pipe, _vim, config.vim_types)

  -- the default require uses C code, so imported modules cannot yield on first level
  -- this should be a reimplementation, but without checking startuptime (probably unnecessary)
  _G.require = function(module)
    local data = package.loaded[module]
    if data then
      return data
    end

    local mod_fn = vim._load_package(module)
    assert(mod_fn, "Failed to load package: " .. module)

    package.loaded[module] = mod_fn()
    return package.loaded[module]
  end

  local old_co_create = coroutine.create
  _G.coroutine.create = function(fn)
    local co = old_co_create(fn)
    co_id_counter = co_id_counter + 1
    active_coroutines[co_id_counter] = co
    return co
  end
end

---return on_control
---@param ctrl_write_pipe uv_pipe_t
---@return fun(err: string, data: string)
local function get_on_control(ctrl_write_pipe)
  return util.dechunk_pipe_msg(
    function(data)
      if data.type == "vim_response" then
        util.debug("Received vim_response:", data.result)
        assert(data.___co_id, "No co_id in response")

        resume(data.___co_id, unpack(data.result or {}))
      elseif data.type == "upvalues" then
        util.debug("Received upvalues:", data)
        local fn = sent_functions[data.id]
        assert(fn, "Could not find fn with id: " .. data.id .. " in " .. _vim.inspect(sent_functions))

        for index, value in pairs(data.upvalues) do
          -- TODO make dynamic
          if type(value) == "table" and value.___serialized_type == "function_ref" then
            value = sent_functions[value.id]
            assert(value, "Could not find sent_function with")
          end

          debug.setupvalue(fn, index, value)
        end
      elseif data.type == "proxy_call" then
        util.debug("Received proxy_call:", data)

        local fn = sent_functions[data.id]
        assert(fn, "Could not find fn with id: " .. data.id .. " in " .. _vim.inspect(sent_functions))

        local co = coroutine.create(function()
          fn(unpack(data.args))
        end)

        -- start new coroutine
        resume_check_err(co)

        -- no response
      elseif data.type == "delete" then
        if data.kind == "function" then
          util.debug("Deleting function with id:", data.id)

          assert(sent_functions[data.id],
            "Could not find fn with id: " .. data.id .. " in " .. _vim.inspect(sent_functions))
          sent_functions[data.id] = nil

          send_ctrl_msg(ctrl_write_pipe, false, {
            type = "delete_response",
            kind = "function",
            id = data.id
          })
        end
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
---@param config_str string
---@param arg_str string
---@param arg_len integer
function M.run(write_fd, read_fd, cb_string, config_str, arg_str, arg_len)
  config = _vim.mpack.decode(config_str)
  util.print_debug = config.debug or false

  util.debug("Starting thread")

  local args = _vim.mpack.decode(arg_str)

  local ctrl_write_pipe = util.open_fd(write_fd)
  local ctrl_read_pipe = util.open_fd(read_fd)

  init_globals(ctrl_write_pipe)

  local co = coroutine.create(function()
    local fn, err = loadstring(cb_string)
    assert(fn, "Failed to load string: " .. (err or ""))
    -- TODO isolate
    fn(unpack(args, 1, arg_len))
  end)

  ctrl_read_pipe:read_start(get_on_control(ctrl_write_pipe))

  resume_check_err(co)

  uv.run()
end

return M
