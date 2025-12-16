-- LLM Quorum service contract
--[[
This contract provides an interface for other contracts to request LLM services
with consensus across multiple different models (platforms).

Instead of checking consensus between different nodes running the same model
(like llm-service.lua), this contract sends the same request to multiple
different models and checks consensus between their responses.

It delegates the actual LLM processing to the llm-service contract.
]]

state.var {
  owner = state.value(),
  llm_service = state.value(),  -- address of the llm-service contract

  last_request_id = state.value(),
  requests = state.map(),       -- request_id -> request: {contract, callback, args, quorum_threshold, num_models}
  results = state.map(2)        -- request_id + index -> result string
}

--------------------------------------------------------------------------------
-- PRIVATE FUNCTIONS
--------------------------------------------------------------------------------

import "check-type.lua"
import "bignum.lua"

local function only_owner()
  assert(system.getSender() == owner:get(), "permission denied")
end

local function clear_request(request_id, num_results)
  requests[request_id] = nil
  for i = 1, num_results do
    results[request_id][i] = nil
  end
end

local function fire_callback(request_id, request, result, num_results)
  -- update the state BEFORE any external call to avoid reentrancy attack
  clear_request(request_id, num_results)

  -- fire the callback
  pcall(contract.call, request.contract, request.callback, unpack(request.args), result)

  -- issue an event
  contract.event("quorum_reached", request_id)
end

local function on_new_request(caller, payment, info, callback, ...)

  assert(caller ~= system.getOrigin(), "this service is intended to be used by other contracts")

  -- check the request info
  check_type(callback, 'string', "callback")
  check_table(info, {
    config = 'string',
    input = 'table',
    models = 'table',
    quorum_threshold = 'number?',
    redundancy = 'number?',
    return_content_within_result_tag = 'boolean?',
    store_result_offchain = 'boolean?',
  }, "request")

  -- validate models list
  local models = info.models
  assert(#models >= 1, "at least one model is required")
  for i, model_info in ipairs(models) do
    check_table(model_info, {
      platform = 'string',
      model = 'string',
    }, "models[" .. i .. "]")
  end

  -- calculate quorum threshold (default: simple majority = floor(n/2) + 1)
  local quorum_threshold = info.quorum_threshold
  if quorum_threshold == nil then
    quorum_threshold = math.floor(#models / 2) + 1
  else
    assert(quorum_threshold >= 1, "quorum_threshold must be at least 1")
    assert(quorum_threshold <= #models, "quorum_threshold cannot exceed the number of models (" .. #models .. ")")
  end

  -- redundancy defaults to 1 if not specified
  local redundancy = info.redundancy
  if redundancy == nil then
    redundancy = 1
  else
    check_type(redundancy, 'number', "redundancy")
    assert(redundancy >= 1, "redundancy must be at least 1")
  end

  -- get the llm-service contract address
  local service = llm_service:get()
  assert(service ~= nil, "llm-service contract address not configured")

  -- get a new request id
  local request_id = last_request_id:get() + 1
  last_request_id:set(request_id)

  -- create the request structure (immutable once saved)
  local request = {
    contract = caller,
    callback = callback,
    args = {...},
    quorum_threshold = quorum_threshold,
    num_models = #models
  }

  -- store the request
  requests[request_id] = request

  -- calculate the total price for the request
  local total_price = bignum.number(0)

  -- create sub-requests for each model
  for _, model_info in ipairs(models) do
    -- get the price for this model
    local price_str = contract.call(service, "get_price", model_info.platform, model_info.model)
    local model_price = from_decimal(price_str, 18) * bignum.number(redundancy)
    total_price = total_price + model_price

    -- build the sub-request info
    local sub_info = {
      config = info.config,
      platform = model_info.platform,
      model = model_info.model,
      input = info.input,
      redundancy = redundancy,
    }

    -- set optional flags
    if info.return_content_within_result_tag ~= nil then
      sub_info.return_content_within_result_tag = info.return_content_within_result_tag
    end
    if info.store_result_offchain ~= nil then
      sub_info.store_result_offchain = info.store_result_offchain
    end

    -- call the llm-service contract, passing request_id as callback argument
    contract.call.value(model_price)(service, "new_request", sub_info, "on_sub_result", request_id)
  end

  -- check the payment for the entire request
  assert(payment >= total_price, "the price for this request is " .. to_decimal(total_price, 18) .. " aergo")

  -- notify listening off-chain services
  contract.event("new_quorum_request", request_id, #models, quorum_threshold)

  return request_id
end

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function constructor()
  owner:set(system.getCreator())
  last_request_id:set(0)
end

--------------------------------------------------------------------------------
-- OWNER FUNCTIONS
--------------------------------------------------------------------------------

function set_owner(new_owner)
  only_owner()
  check_type(new_owner, 'address', "new_owner")
  owner:set(new_owner)
end

function get_owner()
  return owner:get()
end

function set_llm_service(service_address)
  only_owner()
  check_type(service_address, 'address', "service_address")
  llm_service:set(service_address)
  contract.event("llm_service_updated", service_address)
end

function get_llm_service()
  return llm_service:get()
end

--------------------------------------------------------------------------------
-- PRICE FUNCTIONS
--------------------------------------------------------------------------------

-- get total price for a list of models
-- models: array of {platform, model} objects
-- redundancy: optional, defaults to 1
function get_price(models, redundancy)
  check_type(models, 'table', "models")

  if redundancy == nil then
    redundancy = 1
  else
    check_type(redundancy, 'number', "redundancy")
  end

  local service = llm_service:get()
  assert(service ~= nil, "llm-service contract address not configured")

  local total_price = bignum.number(0)
  for _, model_info in ipairs(models) do
    local price_str = contract.call(service, "get_price", model_info.platform, model_info.model)
    assert(price_str ~= nil, "price not configured for " .. model_info.platform .. "/" .. model_info.model)
    local model_price = from_decimal(price_str, 18)
    total_price = total_price + (model_price * bignum.number(redundancy))
  end

  return to_decimal(total_price, 18)
end

--------------------------------------------------------------------------------
-- USER FUNCTIONS
--------------------------------------------------------------------------------

-- trigger a new request, paying for the call with native aergo tokens
function new_request(request, callback, ...)
  local caller = system.getSender()
  local amount = bignum.number(system.getAmount())

  return on_new_request(caller, amount, request, callback, ...)
end

-- trigger a new request, paying for the call with WAERGO tokens
function tokensReceived(operator, from, amount, ...)
  local token = system.getSender()

  local balance_before = bignum.number(contract.balance())
  contract.call(token, "unwrap", amount)
  local balance_after = bignum.number(contract.balance())
  local amount2 = balance_after - balance_before
  assert(amount2 == amount, "invalid unwrapped amount")

  return on_new_request(from, amount, ...)
end

--------------------------------------------------------------------------------
-- CALLBACK FROM LLM-SERVICE
--------------------------------------------------------------------------------

-- called by the llm-service contract when a sub-request is completed
function on_sub_result(request_id, result)
  -- only accept calls from the llm-service contract
  local sender = system.getSender()
  local service = llm_service:get()
  assert(sender == service, "only the llm-service contract can call this function")

  -- get the request
  local request = requests[request_id]
  if request == nil then
    -- request already completed or doesn't exist, ignore
    return
  end

  -- count how many existing results match and find next available slot
  local count = 1  -- count the current result
  local next_slot = 1
  for i = 1, request.num_models do
    local r = results[request_id][i]
    if r == nil then
      next_slot = i
      break
    end
    if r == result then
      count = count + 1
    end
    next_slot = i + 1
  end

  -- check if we reached quorum
  if count >= request.quorum_threshold then
    fire_callback(request_id, request, result, next_slot - 1)
    return
  end

  -- store the result
  results[request_id][next_slot] = result
end

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

function get_request_info(request_id)
  return requests[request_id]
end

function get_request_results(request_id)
  local request = requests[request_id]
  if request == nil then
    return nil
  end

  local result_list = {}
  for i = 1, request.num_models do
    local r = results[request_id][i]
    if r == nil then
      break
    end
    table.insert(result_list, r)
  end
  return result_list
end

function withdraw_fees(amount, recipient)
  only_owner()
  if amount == nil or amount == "" then
    amount = contract.balance()
  end
  if recipient == nil or recipient == "" then
    recipient = owner:get()
  end
  contract.send(recipient, amount)
end

function default()
  -- used to receive aergo tokens (unwrap waergo)
end

--------------------------------------------------------------------------------
-- ABI REGISTRATION
--------------------------------------------------------------------------------

abi.payable(new_request, default)
abi.register(set_owner, set_llm_service, tokensReceived, withdraw_fees, on_sub_result)
abi.register_view(get_price, get_request_info, get_request_results, get_owner, get_llm_service)
