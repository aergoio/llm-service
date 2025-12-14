state.var {
  last_result = state.value(),
  ai_service_address = state.value(),
  ai_service_price = state.value()
}

function constructor()
  last_result:set(nil)
  ai_service_address:set("Amh1Ham8Z65ZmWsgfs3UURSnc9dqc4wR7zdFTrtqYpfHUTBp6Yus")
  ai_service_price:set("1000000000000000000") -- 1 aergo
end

function set_ai_service_contract(address)
  assert(system.getSender() == system.getCreator(), "permission denied")
  ai_service_address:set(address)
end

function set_ai_service_price(price)
  assert(system.getSender() == system.getCreator(), "permission denied")
  ai_service_price:set(price)
end

local function to_decimal(amount, decimal_places)
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
  return result:gsub("%.?0+$", "")
end

function on_llm_result(user_account, result)
  assert(system.getSender() == ai_service_address:get(), "only the LLM service contract can call this function")

  -- store the result
  last_result:set(result)

  -- emit an event
  contract.event("llm_result", result)

end

function new_request(config_hash, user_input)
  -- check the amount paid for this call
  local paid_amount = bignum.number(system.getAmount())
  local service_price = bignum.number(ai_service_price:get())
  assert(paid_amount >= service_price, "you must pay " .. to_decimal(service_price, 18) .. " aergo to call the LLM service")

  local request = {
    config = config_hash, -- hash of the config data
    input = {
      user_input = user_input
    },
    return_content_within_result_tag = true
  }

  -- call the LLM service contract, paying for the call with native tokens
  local ai_service = ai_service_address:get()
  contract.call.value(service_price)(ai_service, "new_request", request, "on_llm_result", system.getSender())

  -- emit an event
  contract.event("request_submitted", request)
end

abi.payable(new_request)
abi.register(on_llm_result, set_ai_service_contract, set_ai_service_price)
