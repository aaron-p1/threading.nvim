# A library for running neovim lua code in a separate os-level thread

**This is still a work in progress!**

The goal of this library is to easily allow running lua code in a separate
os-level thread (`vim.uv.new_thread()`), while still being able to use all
neovim lua functions. This is achieved by sending the unsupported function
calls to the main thread, where they are executed and returning the result
to the thread.

Note: Creating too many threads can lead to performance issues. It is
recommended to only create one thread and use it for example for registering
callbacks (not yet implemented) or communicating with the main thread
to delegate work to the thread (not yet implemented). Or if you have a really
expensive function that you want to run in the background.
Only create additional threads if you really need them.

## Requirements

- neovim `0.10.0` or later

## Features:

- [x] run a lua function in a separate thread
- [x] `vim.api` available
- [ ] `vim.fn` and `vim.cmd` available
- [ ] the remaining `vim.*` available
- [ ] callbacks as parameters to functions that are sent to the main thread
- [ ] userdata e.g. for treesitter functions

## Additional TODO

- stop function from inside the thread
- vim function error handling
- a way to communicate with the thread
- stop all threads when neovim is closed
- maybe add option to let the thread terminate if function ends

## Usage

```lua
local t = require("threading")

local thread = t.start(function()
  -- should not block the main thread
  vim.uv.sleep(5000)

  -- api is still available
  print(vim.api.nvim_get_current_buf())

  -- thread keeps running after the function is done
end)

-- can be stopped with but it is not needed in most cases
-- note: this stops the thread after fully executing the function
t.stop(thread)
```
