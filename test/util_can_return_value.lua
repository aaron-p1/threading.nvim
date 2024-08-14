package.loaded["threading.util"] = nil

local tutil = require("threading.util")

local function can_return_value(fn)
  return tutil.can_return_value(string.dump(fn))
end

local function no_return()
  print("No return")
end

local function return_no_value()
  return
end

local function return_value()
  return 1
end

local function return_multiple_values()
  return 1, 2
end

local function return_call()
  return return_value()
end

local function return_call_multiple_values()
  return return_multiple_values()
end

local function return_call_multiple_values2()
  return return_multiple_values(), 3
end

local function return_call_multiple_values3()
  return 3, return_multiple_values()
end

local function return_call_multiple_values4()
  return return_multiple_values(), return_multiple_values()
end

local function return_call_multiple_values5()
  return return_multiple_values(), return_multiple_values(), 3
end

local function return_call_multiple_values6()
  return return_multiple_values(), return_multiple_values(), return_multiple_values()
end

local function return_call_multiple_values7()
  return return_multiple_values(), return_multiple_values(), return_multiple_values(), 3
end

local function return_no_value_in_if()
  if true then
    return
  end
end

local function return_in_if()
  if true then
    return 1
  end
end

local upvalue = "first"

local fn_upvalue = function(prefix)
  print(prefix, upvalue)
  return nil
end

assert(not can_return_value(no_return), "no_return: false")
assert(not can_return_value(return_no_value), "return_no_value: false")
assert(can_return_value(return_value), "return_value: true")
assert(can_return_value(return_multiple_values), "return_multiple_values: true")
assert(can_return_value(return_call), "return_call: true")
assert(can_return_value(return_call_multiple_values), "return_call_multiple_values: true")
assert(can_return_value(return_call_multiple_values2), "return_call_multiple_values2: true")
assert(can_return_value(return_call_multiple_values3), "return_call_multiple_values3: true")
assert(can_return_value(return_call_multiple_values4), "return_call_multiple_values4: true")
assert(can_return_value(return_call_multiple_values5), "return_call_multiple_values5: true")
assert(can_return_value(return_call_multiple_values6), "return_call_multiple_values6: true")
assert(can_return_value(return_call_multiple_values7), "return_call_multiple_values7: true")
assert(not can_return_value(return_no_value_in_if), "return_no_value_in_if: false")
assert(can_return_value(return_in_if), "return_in_if: true")
assert(can_return_value(fn_upvalue), "fn_upvalue: true")

print("PASSED")
