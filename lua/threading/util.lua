local M = {}

local uv = vim.uv

local data_separator = ":"

M.print_debug = false

-- use native vim in thread
local __vim = _vim or vim

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

    print(unpack(args))
  end
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

function M.find_max_index(tbl)
    local max_index = 0
    for index, _ in pairs(tbl) do
        if type(index) == "number" and index > max_index then
            max_index = index
        end
    end
    return max_index
end

---open a fd in new pipe
---@param fd integer
---@return uv_pipe_t
function M.open_fd(fd)
  local read_pipe = uv.new_pipe(false)
  read_pipe:open(fd)

  return read_pipe
end

---write number of bytes and data to pipe. Read with dechunk_pipe_msg
---@param pipe uv_pipe_t
---@param data any
function M.write_to_pipe(pipe, data)
  local data_str = __vim.mpack.encode(data)
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
      local all_data = prev_data .. data

      -- TODO maybe find ":" and substring for performance
      local recv_len, recv_data = string.match(data, "^(%d+)" .. data_separator .. "(.*)$")
      assert(recv_len and recv_data, "Failed to parse data")
      recv_len = tonumber(recv_len)

      local first_data = recv_data:sub(1, recv_len)

      if #first_data < recv_len then
        M.debug(string.format("Not enough data: %s/%s", #first_data, recv_len))
        prev_data = all_data
        return
      end

      prev_data = recv_data:sub(recv_len + 1)

      local ok, data_table = pcall(vim.mpack.decode, first_data)

      if not ok or type(data_table) ~= "table" then
        print("Failed to decode data: ", first_data)
        return
      end

      cb(data_table)
    end
  end
end

return M
