local M = {}

local uv = vim.uv

M.print_debug = false

---open a fd in new pipe
---@param fd integer
---@return uv_pipe_t
function M.open_fd(fd)
  local read_pipe = uv.new_pipe(false)
  read_pipe:open(fd)

  return read_pipe
end

---print debug message
---@param ... any
---@return nil
function M.debug(...)
  if M.print_debug then
    local args = { ... }

    for i = 1, #args do
      if type(args[i]) == "table" then
        args[i] = vim.inspect(args[i])
      end
    end

    print(unpack(args))
  end
end

return M
