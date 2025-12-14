# Aergo LLM Service

A decentralized LLM (Large Language Model) service for the Aergo blockchain

Smart contracts can request LLM completions, which are processed by authorized off-chain nodes and returned via callbacks

## Components

### Smart Contract

[Lua contract](contract/llm-service.lua) that:
- Accepts LLM requests from other contracts (paid in AERGO or WAERGO)
- Manages authorized nodes and pricing per platform/model
- Supports redundancy (multiple nodes must agree on result)
- Fires callbacks with results to the requesting contract

### Backend Nodes

[Off-chain Node.js service](nodes/llm-service.js) that:
- Listens for `new_request` events from the contract
- Fetches config and inputs from storage
- Calls LLM APIs (OpenAI, Anthropic, etc.)
- Submits results back to the contract

### Supported Platforms

- OpenAI (GPT-4, etc.)
- Anthropic (Claude)
- Google Gemini
- Grok (xAI)
- Groq
- DeepSeek
- Alibaba (Qwen)
- Moonshot (Kimi)
- Zhipu (GLM)
- Perplexity

## Usage

### Running the Node

```bash
cd nodes
npm install
node llm-service.js testnet   # or mainnet, local
```

The node generates an account on first run (saved to `nodes/account.data`). Add this address as an authorized node in the contract

### Contract Integration

From another Aergo contract:

```lua
  local request = {
    config = "<config_hash>",    -- hash pointing to stored prompt config
    input = {                    -- input values (can be hashes of off-chain stored content)
      user_input = "<hash>",     -- key names are free, include them on the prompt as {{user_input}} for replacement
      contract_input = "..."
    },
    redundancy = 1               -- number of nodes that must agree
  }

  contract.call.value(llm_service_price)(llm_service_address, "new_request", request, "my_callback", arg1, arg2)
```

The callback receives the result as the last argument

```lua
function my_callback(arg1, arg2, result)
  assert(system.getSender() == llm_service_address, "only the LLM service contract can call this function")

  -- do something with the result
  ...

end
```
