local M = {}

local uv = vim.uv

local data_separator = ":"

M.print_debug = false

-- use native vim in thread
local __vim = _vim or vim


---@type table<string, string[]> bytecodes that are executed as return statements. Depends on lua version
---Generated with get_luajit_return_bytecodes.sh
local return_bytecodes = {
  ["2.1"] = {
    "\000\074", -- RET
    "\000\073", -- RETM
    "\000\076", -- RET1
    "\000\067", -- CALLMT
    "\000\068", -- CALLT
  }
}

local lua_version = jit.version:match("%d+%.%d+")
local current_return_bytecodes = return_bytecodes[lua_version]

---print debug message
---@param ... any
---@return nil
function M.debug(...)
  if M.print_debug then
    local args = { ... }

    for i = 1, #args do
      if type(args[i]) == "table" then
        args[i] = __vim.inspect(args[i])
      end
    end

    local prefix = __vim.is_thread() and "Thread:" or "Main:"

    print(prefix, unpack(args))
  end
end

---shallow copy a table
---@param tbl table
---@return table
function M.tbl_copy(tbl)
  local new_tbl = {}

  for k, v in pairs(tbl) do
    new_tbl[k] = v
  end

  return new_tbl
end

---append a value to a table without modifying the original
---@param tbl table
---@param value any
---@return table
function M.fappend(tbl, value)
  local new_tbl = {}

  for i = 1, #tbl do
    new_tbl[i] = tbl[i]
  end

  new_tbl[#new_tbl + 1] = value

  return new_tbl
end

---returns the highest number index in a table
---@param tbl table
---@return number
function M.find_max_index(tbl)
  local max_index = 0
  for index, _ in pairs(tbl) do
    if type(index) == "number" and index > max_index then
      max_index = index
    end
  end
  return max_index
end

---returns all functions in a table
---@param tbl table
---@return function[]
function M.get_functions(tbl)
  local functions = {}

  for _, v in pairs(tbl) do
    if type(v) == "function" then
      functions[#functions + 1] = v
    elseif type(v) == "table" then
      local sub_functions = M.get_functions(v)

      __vim.list_extend(functions, sub_functions)
    end
  end

  return functions
end

---open a fd in new pipe
---@param fd integer
---@return uv_pipe_t
function M.open_fd(fd)
  local pipe = uv.new_pipe(false)
  assert(pipe, "Failed to create pipe")
  pipe:open(fd)

  return pipe
end

---write number of bytes and data to pipe. Read with dechunk_pipe_msg
---@param pipe uv_pipe_t
---@param data any
function M.write_to_pipe(pipe, data)
  local ok, data_str = pcall(__vim.mpack.encode, data)

  if not ok then
    M.debug(__vim.inspect(data))
    error(debug.traceback(data_str))
  end

  local len = #data_str

  pipe:write(len .. data_separator .. data_str)
end

---dechunk control messages
---@param cb fun(data: table)
---@param err_cb fun(err: string)
---@param closing_cb function?
---@return fun(err: string, data: string)
function M.dechunk_pipe_msg(cb, err_cb, closing_cb)
  local prev_data = ""

  return function(err, data)
    if err then
      err_cb(err)
      return
    end

    if data == nil then
      M.debug("Pipe closed")
      if closing_cb then
        closing_cb()
      end
    else
      prev_data = prev_data .. data

      while prev_data ~= "" do
        -- TODO maybe find ":" and substring for performance
        local separator_start, separator_end = prev_data:find(data_separator)
        if not separator_start then
          M.debug("Not enough data")
          return
        end

        local recv_len = tonumber(prev_data:sub(1, separator_start - 1))
        local recv_data = prev_data:sub(separator_end + 1)

        assert(type(recv_len) == "number", "Invalid length: " .. recv_len)

        local first_data = recv_data:sub(1, recv_len)

        if #first_data < recv_len then
          M.debug(string.format("Not enough data: %s/%s", #first_data, recv_len))
          return
        end

        prev_data = recv_data:sub(recv_len + 1)

        local ok, data_table = pcall(__vim.mpack.decode, first_data)

        if not ok or type(data_table) ~= "table" then
          print("Failed to decode data: ", first_data)
          return
        end

        cb(data_table)
      end
    end
  end
end

---checks if `fn_str` has a return statement with a value
---@param fn_str string dumped function
---@return boolean has_return
function M.can_return_value(fn_str)
  -- incompatible luajit version
  if not current_return_bytecodes then
    return true
  end

  for _, ret_code in ipairs(current_return_bytecodes) do
    if string.find(fn_str, ret_code) then
      return true
    end
  end

  return false
end

---returns all upvalues of a function
---@param fn function
---@return table<string, any>
function M.get_upvalues(fn)
  local upvalues = {}

  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then
      break
    end

    upvalues[i] = value
  end

  return upvalues
end

---returns indices of already sent upvalues (upvalues shared between functions)
---@param fn function
---@param existing_functions table<integer, function>
---@return [integer, integer, integer][] indices {fn upvalue id, existing fn id, existing fn upvalue id}
local function get_shared_upvalues(fn, fn_id, existing_functions)
  local shared_upvalues = {}

  for i = 1, math.huge do
    local name = debug.getupvalue(fn, i)
    if not name then
      break
    end

    local upvalue_id = debug.upvalueid(fn, i)

    for id, ex_fn in pairs(existing_functions) do
      if id ~= fn_id then
        for j = 1, math.huge do
          local ex_name = debug.getupvalue(ex_fn, j)
          if not ex_name then
            break
          end

          if upvalue_id == debug.upvalueid(ex_fn, j) then
            shared_upvalues[#shared_upvalues + 1] = { i, id, j }
          end
        end
      end
    end
  end

  return shared_upvalues
end

---convert any type of `data` (except userdata and thread) to a serializable format
---TODO handle metatables
---@param data any
---@param id_counter integer id to start from
---@param functions table<integer, function> existing function mappings
---@param with_function_proxies boolean
---@return nil|boolean|number|string|table serializable data that can be serialized with mpack
---@return table<integer, function> functions mapping from ID to function for later identification
---@return integer max_id for setting IDs
function M.to_serializable(data, id_counter, functions, with_function_proxies)
  assert(type(data) ~= "userdata", "Cannot serialize userdata")
  assert(type(data) ~= "thread", "Cannot serialize coroutine thread")

  local dtype = type(data)

  if dtype ~= "table" and dtype ~= "function" then
    return data, functions, id_counter
  elseif dtype == "table" then
    local result = {}

    for k, v in pairs(data) do
      result[k], functions, id_counter = M.to_serializable(v, id_counter, functions, with_function_proxies)
    end

    return result, functions, id_counter
  else
    -- type function
    local same_fn_id
    for id, fn in pairs(functions) do
      if fn == data then
        same_fn_id = id
        break
      end
    end

    if same_fn_id then
      return {
        ___serialized_type = "function_ref",
        id = same_fn_id
      }, functions, id_counter
    end

    local dumped_function = string.dump(data)

    id_counter = id_counter + 1
    local current_fn_id = id_counter
    functions[id_counter] = data

    if with_function_proxies and not M.can_return_value(dumped_function) then
      return {
        ___serialized_type = "function_proxy",
        id = current_fn_id
      }, functions, id_counter
    end

    local current_shared_upvalues = get_shared_upvalues(data, current_fn_id, functions)

    local s_upvalues
    s_upvalues, functions, id_counter = M.to_serializable(
      M.get_upvalues(data), id_counter, functions, with_function_proxies)

    return {
      ___serialized_type = "function",
      id = current_fn_id,
      fn = dumped_function,
      upvalues = s_upvalues,
      shared_upvalues = current_shared_upvalues
    }, functions, id_counter
  end
end

---create a garbage collector tracker
---@param gc_cb fun(id: integer)
---@param id integer
---@return userdata tracker
local function create_gc_tracker(gc_cb, id)
  local ud = newproxy(true)
  getmetatable(ud).__gc = function()
    gc_cb(id)
  end
  return ud
end

---get function that overrides `fn`
---@param id integer
---@param fn function
---@param fn_cb fun(fn: function, id: integer)?
---@param gc_cb fun(id: integer)?
---@return function
local function get_overridden_fn(id, fn, fn_cb, gc_cb)
  local gc_tracker
  if gc_cb then
    gc_tracker = create_gc_tracker(gc_cb, id)
  end

  return function(...)
    local result = { fn(...) }

    if gc_tracker then
      -- use it but don't do anything
      gc_tracker = gc_tracker
    end

    if fn_cb then
      fn_cb(fn, id)
    end

    return unpack(result)
  end
end

---convert from a serializable format to the original format
---@param data nil|boolean|number|string|table|SerializedFunction
---@param existing_functions? table<integer, ExistingFunctionDefinition> existing function mappings
---@param fn_cb? fun(fn: function, id: integer) called after executing the functions in `data`
---@param gc_cb? fun(id: integer) called when garbage collecting a function
---@param pr_cb? fun(id: integer, args: table) called when calling a proxied function
---@return nil|boolean|number|string|table|function original data
---@return table<integer, ExistingFunctionDefinition>
function M.from_serializable(data, existing_functions, fn_cb, gc_cb, pr_cb)
  existing_functions = existing_functions or {}

  if type(data) ~= "table" then
    return data, existing_functions
  end

  if data.___serialized_type == "function" then
    assert(existing_functions[data.id] == nil, "Function already exists with ID: " .. data.id)

    local fn = loadstring(data.fn)
    assert(fn, "Failed to load function")

    local overridden_fn = get_overridden_fn(data.id, fn, fn_cb, gc_cb)

    existing_functions[data.id] = {
      fn = fn,
      refcount = 1,
      upvalue_func_ids = {}
    }

    for index, value in pairs(data.upvalues) do
      local orig_value
      orig_value, existing_functions = M.from_serializable(value, existing_functions, fn_cb, gc_cb, pr_cb)

      if type(orig_value) == "function" then
        existing_functions[data.id].upvalue_func_ids[index] = value.id
      end

      debug.setupvalue(fn, index, orig_value)
    end

    for _, shared_upvalue in ipairs(data.shared_upvalues) do
      local fn_upvalue_id, ex_fn_id, ex_fn_upvalue_id = unpack(shared_upvalue)

      local ex_fn = existing_functions[ex_fn_id]
      assert(ex_fn, "Could not find function with ID: " .. ex_fn_id)

      debug.upvaluejoin(fn, fn_upvalue_id, ex_fn.fn, ex_fn_upvalue_id)
    end

    return overridden_fn, existing_functions
  elseif data.___serialized_type == "function_proxy" then
    assert(pr_cb, "Cannot create function proxy without proxy callback")
    local gc_tracker
    if gc_cb then
      gc_tracker = create_gc_tracker(gc_cb, data.id)
    end

    local overridden_fn = function(...)
      pr_cb(data.id, { ... })

      if gc_tracker then
        -- use it but don't do anything
        gc_tracker = gc_tracker
      end
    end

    existing_functions[data.id] = {
      fn = overridden_fn,
      refcount = 1,
      upvalue_func_ids = {}
    }

    return overridden_fn, existing_functions
  elseif data.___serialized_type == "function_ref" then
    local ex_fn = existing_functions[data.id]
    assert(ex_fn, "Could not find function with ID: " .. data.id)

    ex_fn.refcount = ex_fn.refcount + 1
    return get_overridden_fn(data.id, ex_fn.fn, fn_cb, gc_cb), existing_functions
  end

  local result = {}

  for k, v in pairs(data) do
    result[k], existing_functions = M.from_serializable(v, existing_functions, fn_cb, gc_cb, pr_cb)
  end

  return result, existing_functions
end

return M
