local util = require("threading.util")

local M = {}

local uv = vim.uv

---@alias uv_thread userdata

---@class ThreadingThread
---@field thread uv_thread
---@field ctrl_read_pipe uv_pipe_t
---@field ctrl_write_pipe uv_pipe_t

---@class VimCall
---@field keys string[]
---@field args any[]

---@class VimGet
---@field keys string[]

---@class VimAssign
---@field keys string[]
---@field value any

local disabled_types = {
  ["vim"] = { "uv", "loop" }
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

---run vim function based on data
---@param data VimCall
---@return any
local function handle_vim_call(data)
  local value = get_vim_key(data.keys)

  if value == nil then
    print("Could not find value to assign to", vim.inspect(data))
  else
    return value(unpack(data.args))
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
---@param ctrl_write_pipe uv_pipe_t
---@return fun(err: string, data: string)
local function get_on_control(ctrl_write_pipe)
  return util.dechunk_pipe_msg(
    function(data)
      if data.type == "vim" then
        vim.schedule(function()
          local result

          -- TODO handle errors
          if data.kind == "call" then
            result = handle_vim_call(data)
          elseif data.kind == "get" then
            result = handle_vim_get(data)
          elseif data.kind == "set" then
            result = handle_vim_set(data)
          else
            print("Unknown kind: ", data.kind)
          end

          util.write_to_pipe(ctrl_write_pipe, {
            type = "vim_response",
            result = result
          })
        end)
      end
    end,
    function(err)
      print("Error in control pipe: ", err)
    end
  )
end

---returns config for thread
---@return table
local function get_config()
  return {
    vim_types = M._vim_types
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
