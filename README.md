# A library for running neovim lua code in a separate os-level thread

**This is still a work in progress!**

The goal of this library is to easily allow running lua code in a separate
os-level thread (`vim.uv.new_thread()`), while still being able to use all
neovim lua functions. This is achieved by sending the unsupported function
calls to the main thread, where they are executed and returning the result
to the thread.

**Note**: Creating too many threads can be inefficient. It is recommended to only
create one thread and use it for example for registering callbacks
(not yet implemented) or communicating with the main thread to delegate work
to the thread (not yet implemented). Or if you have a really expensive function
that you want to run in the background. Only create additional threads if you
really need them.

## Requirements

- neovim `0.10.0` or later

## Features:

- [x] run a lua function in a separate thread
- [x] `vim.*` should only be sent to the main thread if they are not supported
- [x] `vim.api` available
- [x] `vim.o` available
- [x] `vim.fn` and `vim.cmd` available
- [ ] `vim.opt` available
- [ ] the remaining `vim.*` available
- [x] callbacks as parameters to functions that are sent to the main thread
- [ ] metatables e.g. `vim.iter`
- [ ] userdata e.g. for treesitter functions
- [x] require with calls to main thread work
- [ ] `vim.run_on_main_thread` function to run a function on the main thread

**Note**: The current implementation of callbacks being sent to the main thread
needs to track if the callback is garbage collected by lua. This works in most
cases but if you use a recursive function, it will not be deleted and therefore
cause a small memory leak until the thread is stopped. But this should not
matter in most cases because it only keeps uniquely defined callbacks. (If the
same callback gets used multiple times, it will only be sent once.) So as
long as you do not have tens of megabytes of source files that are
recursive functions and get sent to the main thread, you should not even
notice it.

## Additional TODO

- vim function error handling
- check if coroutines are working
- check why so many threads get created when running the tests a single time
- make accessing vim functions more dynamic so even long chains of keys work
- a way to communicate with the thread
- stop all threads when neovim is closed
- maybe add option to let the thread terminate if function ends
- mutable tables
- make changing upvalue to a function value work
- `mpack.encode` may fail if data is too large

## Usage

```lua
local t = require("threading")

local thread = t.start(function(param1, param2)
  -- should not block the main thread
  vim.uv.sleep(5000)

  -- api is still available
  print(vim.api.nvim_get_current_buf())

  local a = 0
  vim.keymap.set("n", "<Leader>test", function()
    -- This function would be run on the main thread, because I did not find a
    -- way to pause the main thread when the function needs to return something.

    -- The thread local variable `a` still works because after each call
    -- the updated variables get sent back to the thread.
    -- (as long as it does not become a new function or userdata)
    a = a + 1
    print(a)
  end)

  -- thread keeps running after the function is done
end, { "param1", "param2" })

-- can be stopped with this but it is not needed in most cases
-- note: this stops the thread after fully executing the function
t.stop(thread)
-- inside the thread it can be stopped with `vim.stop_thread()`
```
