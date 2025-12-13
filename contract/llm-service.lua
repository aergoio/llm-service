-- LLM service contract
--[[
This contract provides an interface for other contracts to request LLM services.
It uses external authorized nodes to process the requests and return the results.

The contract charges a fee for each request, which can be paid in native AERGO tokens
or in WAERGO tokens (wrapped AERGO).

The contract owner can set the prices for different LLM platforms and models.
]]

state.var {
  owner = state.value(),
  authorized_nodes = state.value(), -- array of authorized node addresses

  prices = state.map(2),      -- platform + model -> price

  last_request_id = state.value(),
  requests = state.map(),     -- request_id -> request: {contract, payment, config, input, callback, args}
  submissions = state.map(2)  -- request_id + index -> submission: {node, result}
}

--------------------------------------------------------------------------------
-- PRIVATE FUNCTIONS
--------------------------------------------------------------------------------

import "check-type.lua"
import "bignum.lua"

local function only_owner()
  assert(system.getSender() == owner:get(), "permission denied")
end

local function is_authorized_node(node_address, nodes)
  for i = 1, #nodes do
    if nodes[i] == node_address then
      return true
    end
  end
  return false
end

local function on_new_request(caller, payment, info, callback, ...)

  assert(caller ~= system.getOrigin(), "this service is intended to be used by other contracts")

  -- check the request info
  check_type(callback, 'string', "callback")
  check_table(info, {
    platform = 'string?',
    model = 'string?',
    config = 'string',
    input = 'table',
    return_content_within_result_tag = 'boolean?',
    store_result_offchain = 'boolean?',
  }, "request")

  -- redundancy defaults to 1 if not specified
  local redundancy = info.redundancy
  if redundancy == nil then
    redundancy = 1
  else
    check_type(redundancy, 'number', "redundancy")
    assert(redundancy >= 1, "redundancy must be at least 1")
  end

  -- validate redundancy against available nodes
  local nodes = authorized_nodes:get()
  assert(redundancy <= #nodes, "redundancy cannot exceed the number of authorized nodes (" .. #nodes .. ")")

  -- get the price for the platform and model
  local price_str = get_price(info.platform, info.model)
  --assert(price_str ~= nil, "platform and model not supported: [" .. info.platform .. "] [" .. info.model .. "]")
  assert(price_str ~= nil, "prices are not configured")
  local base_price = from_decimal(price_str, 18)

  -- total price is proportional to redundancy
  local total_price = base_price * bignum.number(redundancy)

  -- check the payment for this call
  assert(payment >= total_price, "the price for this call is " .. to_decimal(total_price, 18) .. " aergo (base: " .. price_str .. " x " .. redundancy .. " redundancy)")

  -- create the request structure
  local request = {
    contract = caller,
    payment = bignum.tostring(payment),
    platform = info.platform,
    model = info.model,
    config = info.config,
    input = info.input,
    callback = callback,
    args = {...},
    redundancy = redundancy
  }

  -- set the optional flags
  if info.return_content_within_result_tag ~= nil then
    request.return_content_within_result_tag = info.return_content_within_result_tag
  end
  if info.store_result_offchain ~= nil then
    request.store_result_offchain = info.store_result_offchain
  end

  -- get a new request id
  local request_id = last_request_id:get() + 1
  last_request_id:set(request_id)

  -- store the request
  requests[request_id] = request

  -- notify the listening off-chain nodes
  contract.event("new_request", request_id, redundancy)

  return request_id
end

local function fire_callback(request_id, request, result, to_clear)
  -- update the state BEFORE any external call to avoid reentrancy attack
  -- clear the state variables
  requests[request_id] = nil
  for i = 1, to_clear do
    submissions[request_id][i] = nil
  end

  -- fire the callback
  pcall(contract.call, request.contract, request.callback, unpack(request.args), result)

  -- issue an event
  contract.event("processed", request_id)
end

--------------------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------------------

function constructor()
  owner:set(system.getCreator())
  last_request_id:set(0)
  authorized_nodes:set({})
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

--------------------------------------------------------------------------------
-- AUTHORIZED NODES MANAGEMENT
--------------------------------------------------------------------------------

function add_authorized_node(node_address)
  only_owner()
  check_type(node_address, 'address', "node_address")

  local nodes = authorized_nodes:get()
  if nodes == nil then
    nodes = {}
  end

  -- check if already authorized
  for i = 1, #nodes do
    if nodes[i] == node_address then
      return  -- already in the list
    end
  end

  -- add to the array
  table.insert(nodes, node_address)
  authorized_nodes:set(nodes)
  contract.event("node_added", node_address)
end

function remove_authorized_node(node_address)
  only_owner()
  check_type(node_address, 'address', "node_address")

  local nodes = authorized_nodes:get()
  local len = #nodes
  for i = 1, len do
    if nodes[i] == node_address then
      -- swap with last element and remove last
      if i < len then
        nodes[i] = nodes[len]
      end
      table.remove(nodes, len)
      authorized_nodes:set(nodes)
      contract.event("node_removed", node_address)
      return
    end
  end
end

function get_authorized_nodes()
  return authorized_nodes:get()
end

function is_node_authorized(node_address)
  local nodes = authorized_nodes:get()
  return is_authorized_node(node_address, nodes)
end

--------------------------------------------------------------------------------
-- PRICE FUNCTIONS
--------------------------------------------------------------------------------

function set_price(platform, model, price)
  only_owner()
  check_type(platform, 'string', "platform")
  check_type(model, 'string', "model")
  check_type(price, 'string', "price")

  prices[platform][model] = price
  contract.event("price_updated", platform, model, price)
end

function get_price(platform, model)
  platform = platform or ""
  model = model or ""
  local price = prices[platform][model]
  if price == nil then
    price = prices[""][""]
  end
  return price
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
-- NODE FUNCTIONS
--------------------------------------------------------------------------------

function get_request_info(request_id)
  return requests[request_id]
end

function check_submission(request_id, node_address)
  local nodes = authorized_nodes:get()
  local num_total_nodes = #nodes

  assert(is_authorized_node(node_address, nodes), "not authorized")

  if requests[request_id] == nil then
    return "request not found"
  end

  for i = 1, num_total_nodes do
    local submission = submissions[request_id][i]
    if submission == nil then
      -- this node has not submitted a result for this request and it is open to new submissions
      return "OK"
    elseif submission.node == node_address then
      -- this node has already submitted a result for this request
      return "submitted"
    end
  end

  -- this request already has all the submissions but have not reached consensus
  return "no consensus"
end

-- only the authorized nodes can call this function
function send_result(request_id, result)
  local nodes = authorized_nodes:get()
  local num_total_nodes = #nodes

  local sender = system.getSender()
  assert(is_authorized_node(sender, nodes), "not authorized")

  -- convert the request_id to a number if it's a string
  if type(request_id) ~= 'number' then
    request_id = tonumber(request_id)
  end

  -- check if the request exists
  local request = requests[request_id]
  assert(request ~= nil, "request not found")

  -- check for previous submissions
  local last = 0
  local num_equal = 1

  for i = 1, num_total_nodes do
    last = i
    local previous = submissions[request_id][i]
    if previous == nil then
      break
    elseif previous.node == sender then
      assert(false, "already submitted for this request")
    elseif previous.result == result then
      num_equal = num_equal + 1
    end
  end

  -- check if we have enough matching results based on redundancy
  if num_equal >= request.redundancy then
    -- fire the callback
    fire_callback(request_id, request, result, last - 1)
  else
    -- store the result
    submissions[request_id][last] = {
      node = sender,
      result = result
    }
    -- emit event for tracking
    --contract.event("result_submitted", request_id)
  end

end

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

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
-- FEE DELEGATION
--------------------------------------------------------------------------------

function check_delegation()
  return is_node_authorized(system.getSender())
end

--------------------------------------------------------------------------------
-- ABI REGISTRATION
--------------------------------------------------------------------------------

abi.payable(new_request, default)
abi.register(set_price, set_owner, add_authorized_node, remove_authorized_node,
             send_result, tokensReceived, withdraw_fees)
abi.register_view(get_price, get_request_info, check_submission, get_owner, is_node_authorized, get_authorized_nodes)
abi.fee_delegation(send_result)
