
-- convert a big number to a string with decimal places
-- example: 10000000000000000 -> "0.01"
-- example: 123000000000000000 -> "0.123"
function to_decimal(amount, decimal_places)
  local str = bignum.tostring(amount)
  local len = #str

  -- format the number with decimal point
  local result
  if len <= decimal_places then
    -- add leading zeros if needed
    result = "0." .. string.rep("0", decimal_places - len) .. str
  else
    -- insert decimal point decimal_places positions from the right
    result = str:sub(1, len - decimal_places) .. "." .. str:sub(len - decimal_places + 1)
  end

  -- remove trailing zeros after decimal point, and the decimal point if it's not needed
  result = result:gsub("%.?0+$", "")

  return result
end

-- convert a string with decimal places to a big number
-- example: "0.01" -> 10000000000000000
-- example: "0.123" -> 123000000000000000
function from_decimal(num, decimal_places)
  assert(type(num) == 'string', "input must be a string")
  assert(type(decimal_places) == 'number', "decimal_places must be a number")

  -- handle the case where the input is already an integer
  if not string.find(num, "%.") then
    return bignum.number(num .. string.rep("0", decimal_places))
  end

  -- split the number into integer and decimal parts
  local integer_part, decimal_part = string.match(num, "(%d*)%.(%d*)")
  assert(integer_part ~= nil, "invalid number format")

  -- if integer part is empty (e.g., ".123"), treat it as "0"
  if integer_part == "" then
    integer_part = "0"
  end

  -- if decimal part is longer than decimal_places, truncate it
  if #decimal_part > decimal_places then
    decimal_part = decimal_part:sub(1, decimal_places)
  else
    -- pad with zeros if needed
    decimal_part = decimal_part .. string.rep("0", decimal_places - #decimal_part)
  end

  -- combine parts without the decimal point
  local result_str = integer_part .. decimal_part

  -- remove leading zeros (except if the result is just "0")
  result_str = result_str:gsub("^0+", "")
  if result_str == "" then
    result_str = "0"
  end

  return bignum.number(result_str)
end

function bignum_abs(num)
  if bignum.isnegative(num) then
    return bignum.neg(num)
  end
  return num
end
