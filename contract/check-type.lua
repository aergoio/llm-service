-- this file is intended to be imported by other contracts

local function check_type(value, expected_type, name)
  if (value and expected_type == 'address') then    -- a string containing an address
    assert(type(value) == 'string', name .. " must be a string containing an address")
    -- check address length
    assert(#value == 52, string.format("invalid address length for %s (%s): %s", name, #value, value))
    -- check address checksum
    local success = pcall(system.isContract, value)
    assert(success, string.format("invalid address for %s: %s", name, value))
  elseif (value and expected_type == 'ubig') then   -- an unsigned big integer
    assert(bignum.isbignum(value), string.format("invalid type for %s: expected bignum but got %s", name, type(value)))
    assert(value >= bignum.number(0), string.format("%s must be positive number, but got %s", name, bignum.tostring(value)))
  elseif (value and expected_type == 'uint') then   -- an unsigned lua integer
    assert(type(value) == 'number', string.format("invalid type for %s: expected number but got %s", name, type(value)))
    assert(math.floor(value) == value, string.format("%s must be an integer, but got %s", name, value))
    assert(value >= 0, string.format("%s must be 0 or positive. got %s", name, value))
  else
    -- check default lua types
    assert(type(value) == expected_type, string.format("invalid type for %s, expected %s but got %s", name, expected_type, type(value)))
  end
end

local function check_table(value, expected_table, name)
  assert(type(value) == 'table', string.format("invalid type for %s: expected table but got %s", name, type(value)))
  for key, expected_type in pairs(expected_table) do
    -- Check if type is optional (ends with ?)
    local is_optional = string.sub(expected_type, -1) == '?'
    if is_optional then
      expected_type = string.sub(expected_type, 1, -2)  -- remove the trailing ?
    end
    -- Check if key is present (required for non-optional, skip nil for optional)
    if value[key] == nil then
      assert(is_optional, string.format("missing key %s in %s table", key, name))
    else
      check_type(value[key], expected_type, key)
    end
  end
end
