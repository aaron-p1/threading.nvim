local util = require("threading.util")

local M = {}

local uv = vim.uv

---@class ThreadingConfig
---@field debug boolean?
---@field proxy_functions boolean? Whether to run functions without return statements on the child thread (default: true)

---@alias uv_thread userdata

---@class ThreadingThread
---@field thread uv_thread
---@field ctrl_read_pipe uv_pipe_t
---@field ctrl_write_pipe uv_pipe_t
---@field _received_functions table<integer, ExistingFunctionDefinition>
---@field stop fun()
---@field is_running fun(): boolean

---@class VimCall
---@field keys string[]
---@field args any[]

---@class VimGet
---@field keys string[]

---@class VimAssign
---@field keys string[]
---@field value any

---@class SerializedFunction
---@field ___serialized_type "function"
---@field id integer
---@field fn string
---@field upvalues table<integer, any>

---@class SerializedFunctionRef
---@field ___serialized_type "function_ref"
---@field id integer

---@class ExistingFunctionDefinition
---@field fn function
---@field refcount integer
---@field upvalue_func_ids table<integer, integer> used for tracking function values as upvalues

---vim key types not sent to thread because they exist in all versions
local disabled_types = {
  vim = { "uv", "loop" }
}

---get data types of table
---@param entry table
---@param prefix string
---@param limit integer
---@return table
local function get_types(entry, prefix, limit)
  local result = {}

  for k, v in pairs(entry) do
    if disabled_types[prefix] and vim.tbl_contains(disabled_types[prefix], k) then
      goto continue
    end

    local ktype = type(v)
    result[k] = ktype

    if ktype == "table" and limit > 0 then
      if not result.subtypes then
        result.subtypes = {}
      end

      result.subtypes[k] = get_types(v, string.format("%s.%s", prefix, k), limit - 1)
    end

    ::continue::
  end

  return result
end

M._vim_types = get_types(vim, "vim", 2)

---get a vim key depending on keys
---@param keys string[]
---@param skipend boolean?
---@return any
local function get_vim_key(keys, skipend)
  return vim.iter(keys)
      :rskip(skipend and 1 or 0)
      :fold(vim, function(acc, v)
        if acc == nil then
          return nil
        end

        -- TODO handle error
        return acc[v]
      end)
end

---returns a function that sends updated upvalues to the thread
---@param thread ThreadingThread
---@return fun(fn: function, id: integer)
local function get_recv_fn_return_callback(thread)
  return function(fn, id)
    --- TODO what about parameter function accesses parameter function variable
    --- TODO check if function still used (garbage collector)
    --- TODO handle upvalue changed to a function
    local upvalues = util.get_upvalues(fn)

    if not vim.tbl_isempty(upvalues) then
      for i, upvalue in pairs(upvalues) do
        if type(upvalue) == "function" then
          local found_fn_id = thread._received_functions[id].upvalue_func_ids[i]
          assert(found_fn_id, "Function upvalue not found")

          upvalues[i] = {
            ___serialized_type = "function_ref",
            id = found_fn_id
          }
        end
      end

      util.debug("Sending upvalues of id ", id, upvalues)

      util.write_to_pipe(thread.ctrl_write_pipe, {
        type = "upvalues",
        id = id,
        upvalues = upvalues
      })
    end
  end
end

---returns a function that sends a delete request to the thread
---@param thread ThreadingThread
---@return fun(id: integer)
local function get_delete_fn_callback(thread)
  return function(id)
    util.debug("Garbage collection deleting function with id ", id)

    if not thread._received_functions or not thread._received_functions[id] then
      util.debug("All received functions were already deleted")
      return
    end

    thread._received_functions[id].refcount = thread._received_functions[id].refcount - 1

    if thread._received_functions[id].refcount == 0 then
      if not thread.ctrl_write_pipe:is_closing() then
        util.debug("Sending delete request to thread")

        util.write_to_pipe(thread.ctrl_write_pipe, {
          type = "delete",
          kind = "function",
          id = id
        })
      else
        util.debug("Thread does not exist anymore, so only deleting local function")
        thread._received_functions[id] = nil
      end
    end
  end
end

---returns a function that sends the function call to the thread
---@param thread ThreadingThread
---@return fun(fn: function, args: table)
local function get_send_fn_call_callback(thread)
  return function(id, args)
    util.debug("Sending function call with id ", id, " and args ", args)

    util.write_to_pipe(thread.ctrl_write_pipe, {
      type = "proxy_call",
      id = id,
      args = args
    })
  end
end

---convert from serializable format to the original format and set `thread._received_functions`
---@param thread ThreadingThread
---@param data SerializedFunction
---@return nil|boolean|number|string|table|function original
local function from_serializable(thread, data)
  local result
  result, thread._received_functions = util.from_serializable(
    data,
    thread._received_functions,
    get_recv_fn_return_callback(thread),
    get_delete_fn_callback(thread),
    get_send_fn_call_callback(thread)
  )
  return result
end

---run vim function based on data
---@param thread ThreadingThread
---@param data VimCall
---@return any
local function handle_vim_call(thread, data)
  local value = get_vim_key(data.keys)

  if value == nil then
    print("Could not find value to assign to", vim.inspect(data))
  else
    local args = from_serializable(thread, data.args)
    assert(type(args) == "table", "Args must be a table. Probably a bug in the threading library: " .. vim.inspect(args))

    -- TODO check if need to handle nil as parameter
    return value(unpack(args))
  end
end

---get a vim key depending on keys
---@param data VimGet
local function handle_vim_get(data)
  return get_vim_key(data.keys)
end

---assign a value to a vim variable
---@param data VimAssign
local function handle_vim_set(data)
  local value = get_vim_key(data.keys, true)

  if value == nil then
    print("Could not find value to assign to", vim.inspect(data))
  else
    value[data.keys[#data.keys]] = data.value
  end
end

---return on_control
---@param thread ThreadingThread
---@return fun(err: string, data: string)
local function get_on_control(thread)
  return util.dechunk_pipe_msg(
    function(data)
      -- TODO error when unknown
      if data.type == "vim" then
        vim.schedule(function()
          local result

          -- TODO handle errors
          if data.kind == "call" then
            result = { handle_vim_call(thread, data) }
          elseif data.kind == "get" then
            result = { handle_vim_get(data) }
          elseif data.kind == "set" then
            handle_vim_set(data)
          else
            print("Unknown kind: ", data.kind)
          end

          util.write_to_pipe(thread.ctrl_write_pipe, {
            type = "vim_response",
            result = result,
            ___co_id = data.___co_id
          })
        end)
      elseif data.type == "delete_response" then
        if data.kind == "function" then
          util.debug("Deleting function in thread response with id:", data.id)

          assert(thread._received_functions[data.id],
            "Could not find fn with id: " .. data.id .. " in " .. vim.inspect(thread._received_functions))
          thread._received_functions[data.id] = nil
        end
      end
    end,
    function(err)
      print("Error in control pipe: ", err)
    end,
    function()
      thread:stop()
    end
  )
end

---returns config for thread
---@param user_cfg table
---@return table
local function get_config(user_cfg)
  return vim.tbl_extend("force", {
    vim_types = M._vim_types,
    debug = false,
    proxy_functions = true
  }, user_cfg)
end

---start a new thread
---@param callback function
---@param args table?
---@param config ThreadingConfig?
---@return ThreadingThread
function M.start(callback, args, config)
  local ctrl_to_main = uv.pipe({ nonblock = true }, { nonblock = true })
  local ctrl_to_thread = uv.pipe({ nonblock = true }, { nonblock = true })

  assert(ctrl_to_main, "Failed to create pipe")
  assert(ctrl_to_thread, "Failed to create pipe")

  local ctrl_read_pipe = util.open_fd(ctrl_to_main.read)
  local ctrl_write_pipe = util.open_fd(ctrl_to_thread.write)

  local cb_string = string.dump(callback)
  local config_str = vim.mpack.encode(get_config(config or {}))

  -- TODO handle functions and mutable tables
  args = args or {}
  local arg_str = vim.mpack.encode(args)
  local arg_len = util.find_max_index(args)

  local thread = uv.new_thread(function(...)
    require("threading.thread").run(...)
  end, ctrl_to_main.write, ctrl_to_thread.read, cb_string, config_str, arg_str, arg_len)

  assert(thread, "Failed to create thread")

  ---@type ThreadingThread
  local result_thread = {
    thread = thread,
    ctrl_read_pipe = ctrl_read_pipe,
    ctrl_write_pipe = ctrl_write_pipe,
    _received_functions = {},
    stop = M.stop,
    is_running = M.is_running
  }

  ctrl_read_pipe:read_start(get_on_control(result_thread))

  return result_thread
end

---stop a thread by sending a stop message
---@param thread ThreadingThread
function M.stop(thread)
  if thread.ctrl_read_pipe:is_active() then
    thread.ctrl_read_pipe:close()
  end

  if thread.ctrl_write_pipe:is_active() then
    thread.ctrl_write_pipe:close()
  end

  thread._received_functions = {}
end

---check if a thread is running
---@param thread ThreadingThread
---@return boolean
function M.is_running(thread)
  return thread.ctrl_read_pipe:is_active() or thread.ctrl_write_pipe:is_active()
end

return M
