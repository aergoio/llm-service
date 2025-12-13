const client = require('@herajs/client');
const crypto = require('@herajs/crypto');
const process = require('process');
const fs = require('fs');
const { initialize_event_handling } = require('./contract-events.js');
const { process_llm_request } = require('./llm-requests.js');
const { getContent, storeContent } = require('./storage.js');

// This is the address of the LLM Service contract
// You'll need to replace these with your actual contract addresses
const contract_address_testnet = "Amh1Ham8Z65ZmWsgfs3UURSnc9dqc4wR7zdFTrtqYpfHUTBp6Yus"
const contract_address_mainnet = "--insert-contract-address-here--"
var contract_address
var network_address
const gas_price = 5  // 50000000000
const gas_limit = 100000

var chainIdHash
var identity
var account

// Node scheduling variables
var myNodeIndex = -1         // This node's index in the authorized nodes list (0-based)
var numNodes = 0             // Total number of authorized nodes
const BASE_WAIT_TIME = 60000 // Base wait time in milliseconds (60 seconds)

// read the command line argument
const args = process.argv.slice(2)
if (args.length == 0 || (args[0] != 'testnet' && args[0] != 'mainnet' && args[0] != 'local')) {
  var path = require("path");
  var file = path.basename(process.argv[1])
  console.log("node", file, "local")
  console.log(" or")
  console.log("node", file, "testnet")
  console.log(" or")
  console.log("node", file, "mainnet")
  process.exit(1)
}
if (args[0] == 'mainnet') {
  console.log('running on mainnet')
  network_address = 'mainnet-api.aergo.io:7845'
  contract_address = contract_address_mainnet
} else if (args[0] == 'testnet') {
  console.log('running on testnet')
  network_address = 'testnet-api.aergo.io:7845'
  contract_address = contract_address_testnet
} else if (args[0] == 'local') {
  console.log('running on local network')
  network_address = '127.0.0.1:7845'
  contract_address = process.env.PRICE_ORACLE_CONTRACT
  if (!contract_address) {
    console.error("Environment variables for contract addresses not set");
    process.exit(1);
  }
}

const aergo = new client.AergoClient({}, new client.GrpcProvider({url: network_address}));

// read or generate an account for this node
try {
  const privateKey = fs.readFileSync(__dirname + '/account.data')
  console.log('reading account from file...')
  identity = crypto.identityFromPrivateKey(privateKey)
} catch (err) {
  if (err.code == 'ENOENT') {
    console.log('generating new account...')
    identity = crypto.createIdentity()
    fs.writeFileSync(__dirname + '/account.data', identity.privateKey)
  } else {
    console.error(err)
    process.exit(1)
  }
}

console.log('account address:', identity.address);

// Helper function to sleep for a given number of milliseconds
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Fetch this node's index from the contract
async function fetch_node_index() {
  let nodes = await aergo.queryContract(contract_address, "get_authorized_nodes");

  // Handle case where API returns {} instead of [] for empty array
  if (!Array.isArray(nodes)) {
    nodes = [];
  }

  numNodes = nodes.length;

  if (nodes.length === 0) {
    myNodeIndex = -1;
    console.log("No authorized nodes found in contract yet");
    return false;
  }

  myNodeIndex = nodes.findIndex(addr => addr === identity.address);

  if (myNodeIndex === -1) {
    console.log("This node is not yet authorized in the contract");
    console.log("Waiting for authorization... Node address:", identity.address);
    return false;
  }

  console.log(`Node authorized! Index: ${myNodeIndex} (out of ${numNodes} nodes)`);
  return true;
}

// Calculate wait time based on position in round-robin for this request
function calculate_wait_time(request_id, redundancy) {
  if (numNodes === 0) return 0;

  // Determine starting node for this request (round-robin)
  const startNode = request_id % numNodes;

  // Calculate this node's position relative to the start node
  const myPosition = (myNodeIndex - startNode + numNodes) % numNodes;

  // If within redundancy window, no wait needed
  if (myPosition < redundancy) {
    return 0;
  }

  // Otherwise, wait based on how far we are from the redundancy window
  return (myPosition - redundancy + 1) * BASE_WAIT_TIME;
}

// Check if a request is still pending (not yet processed)
async function is_request_pending(request_id) {
  const status = await aergo.queryContract(contract_address, "check_submission", request_id, identity.address);
  return status == "OK";
}

// Resolve content from hash using local storage
function resolveContentFromHash(hash) {
  if (!hash || typeof hash !== 'string') {
    return null;
  }
  // If it's a valid SHA256 hash (64 hex chars), try to retrieve from storage
  if (/^[a-f0-9]{64}$/i.test(hash)) {
    const content = getContent(hash);
    // Convert Buffer to string if needed
    return Buffer.isBuffer(content) ? content.toString('utf8') : content;
  }
  // Otherwise return as-is (might be plain text)
  return hash;
}

// Parse config content in custom format:
// First line (optional): model: platform/model
// Remaining lines (or all lines if no model specified): prompt
function parseConfig(content) {
  if (!content || typeof content !== 'string') {
    return null;
  }

  const lines = content.split('\n');
  if (lines.length < 1) {
    return null;
  }

  const firstLine = lines[0].trim();

  // Check if first line starts with "model: "
  if (firstLine.startsWith('model: ')) {
    // Extract platform/model from first line
    const modelSpec = firstLine.substring(7).trim(); // Remove "model: " prefix
    const slashIndex = modelSpec.indexOf('/');

    if (slashIndex === -1) {
      console.error('Invalid config format: model line must be "model: platform/model"');
      return null;
    }

    const platform = modelSpec.substring(0, slashIndex).trim();
    const model = modelSpec.substring(slashIndex + 1).trim();

    if (!platform || !model) {
      console.error('Invalid config format: platform and model cannot be empty');
      return null;
    }

    // Remaining lines: prompt
    const prompt = lines.slice(1).join('\n');

    return { platform, model, prompt };
  } else {
    // No model specified, entire content is the prompt
    const prompt = content;
    return { platform: null, model: null, prompt };
  }
}

// Build the full prompt from config and user inputs
function buildPrompt(config, inputs) {
  let prompt = config.prompt || '';

  // Replace placeholders in the prompt with resolved input values
  // Supports {{key}} style placeholders
  if (inputs && typeof inputs === 'object') {
    for (const [key, valueHash] of Object.entries(inputs)) {
      const resolvedValue = resolveContentFromHash(valueHash);
      if (resolvedValue !== null) {
        // Replace {{key}} with the resolved value
        const placeholder = new RegExp(`\\{\\{\\s*${key}\\s*\\}\\}`, 'g');
        prompt = prompt.replace(placeholder, resolvedValue);
      }
    }
  }

  return prompt;
}

// Extract content from within <result></result> tags
function extractResultContent(text) {
  if (!text || typeof text !== 'string') {
    return text;
  }

  // Find opening tag
  const openTag = '<result>';
  const closeTag = '</result>';

  const openTagStart = text.indexOf(openTag);
  if (openTagStart === -1) {
    console.warn('No <result> tag found in response, returning original text');
    return text;
  }

  // Content starts after the opening tag
  const contentStart = openTagStart + openTag.length;

  // Find closing tag (optional - LLM might forget it)
  const closeTagStart = text.indexOf(closeTag, contentStart);

  let content;
  if (closeTagStart === -1) {
    // No closing tag, take everything after opening tag
    content = text.substring(contentStart);
  } else {
    content = text.substring(contentStart, closeTagStart);
  }

  return content.trim();
}

// Function to handle LLM request events
async function on_llm_request(event, is_new) {
  try {
    // Skip if this node is not authorized
    if (myNodeIndex === -1) {
      console.log("Ignoring request - this node is not authorized");
      return;
    }

    const request_id = event.args[0];
    const redundancy = event.args[1] || 1;
    console.log(`Received new LLM request with ID: ${request_id}, redundancy: ${redundancy}`);

    // Calculate wait time based on round-robin position
    const waitTime = calculate_wait_time(request_id, redundancy);
    const startNode = request_id % numNodes;
    const myPosition = (myNodeIndex - startNode + numNodes) % numNodes;

    console.log(`My position for request ${request_id}: ${myPosition}, wait time: ${waitTime}ms`);

    // Wait if we're not in the immediate execution group
    if (waitTime > 0) {
      console.log(`Waiting ${waitTime}ms before processing request ${request_id}...`);
      await sleep(waitTime);

      // After waiting, check if request is still pending
      const stillPending = await is_request_pending(request_id);
      if (!stillPending) {
        console.log(`Request ${request_id} already processed, skipping`);
        return;
      }
      console.log(`Request ${request_id} still pending, processing now`);
    }

    // Query the contract to get request details
    const request_info = await aergo.queryContract(contract_address, "get_request_info", request_id);
    console.log("Request details:", request_info);

    if (!request_info) {
      console.error(`No details found for request ID: ${request_id}`);
      return;
    }

    // Retrieve config from storage using the config hash
    // Config format: first line is platform/model, rest is the prompt
    const configHash = request_info.config;
    const configBuffer = getContent(configHash);

    if (!configBuffer) {
      console.error(`Config not found in storage for hash: ${configHash}`);
      return;
    }

    // Convert Buffer to string if needed
    const configContent = Buffer.isBuffer(configBuffer) ? configBuffer.toString('utf8') : configBuffer;
    const config = parseConfig(configContent);
    if (!config) {
      console.error(`Invalid config format for hash: ${configHash}`);
      return;
    }

    console.log("Retrieved config:", { platform: config.platform, model: config.model, promptLength: config.prompt.length });

    // Get platform and model from config, or fall back to request_info
    let platform = config.platform;
    let model = config.model;

    if (!platform || !model) {
      // Try to get from request_info
      platform = platform || request_info.platform;
      model = model || request_info.model;

      if (!platform || !model) {
        console.error(`Invalid config: missing platform or model in both config and request_info`);
        return;
      }

      console.log("Using platform/model from request_info:", { platform, model });
    }

    // Build the prompt from config and resolve input hashes
    const prompt = buildPrompt(config, request_info.input);
    console.log("Built prompt:", prompt.substring(0, 200) + (prompt.length > 200 ? '...' : ''));

    // Check if we need to extract content from <result> tags
    const extractResultTag = request_info.return_content_within_result_tag === true;
    // Check if we need to store result off-chain and return only the hash
    const storeResultOffchain = request_info.store_result_offchain === true;

    // Process the LLM request
    process_llm_request(platform, model, prompt)
      .then(async result => {
        console.log(`Got result for request ${request_id}:`, result);

        // Extract content from <result> tags if flag is set
        if (extractResultTag) {
          result = extractResultContent(result);
          console.log(`Extracted result content: ${result}`);
        }

        // Store result off-chain and return hash if flag is set
        if (storeResultOffchain) {
          const hash = storeContent(result);
          console.log(`Stored result off-chain, hash: ${hash}`);
          result = hash;
        }

        // Final check before submitting (in case another node beat us)
        const stillPending = await is_request_pending(request_id);
        if (!stillPending) {
          console.log(`Request ${request_id} was processed while we were computing, skipping submission`);
          return;
        }

        submit_result(request_id, result);
      })
      .catch(error => {
        console.error(`Error processing LLM request ${request_id}:`, error);
      });
  } catch (error) {
    console.error("Error handling LLM request:", error);
  }
}

// Handle node_added and node_removed events to update state
async function on_node_list_changed(event) {
  console.log(`Node list changed (${event.eventName}), refreshing...`);
  await fetch_node_index();
}

// Function to handle contract events
function on_contract_event(event, is_new) {
  console.log("Received contract event:", event.eventName);

  if (event.eventName === "new_request") {
    on_llm_request(event, is_new);
  } else if (event.eventName === "node_added" || event.eventName === "node_removed") {
    on_node_list_changed(event);
  }
}

// send the result to the LLM Service smart-contract
async function submit_result(request_id, result) {
  account.nonce += 1

  const tx = {
    //type: 5,  // contract call
    type: 3,  // contract call with fee delegation
    nonce: account.nonce,
    from: identity.address,
    to: contract_address,
    payload: JSON.stringify({
      "Name": "send_result",
      "Args": [request_id, result]
    }),
    amount: '0 aer',
    limit: gas_limit,
    chainIdHash: chainIdHash
  };

  console.log("sending transaction with result:", result)

  try {
    tx.sign = await crypto.signTransaction(tx, identity.keyPair);
    tx.hash = await crypto.hashTransaction(tx, 'bytes');
    const txhash = await aergo.sendSignedTransaction(tx);
    const txReceipt = await aergo.waitForTransactionReceipt(txhash);

    console.log("transaction receipt:", txReceipt)

    if (txReceipt.status === "SUCCESS") {
      console.log("Successfully submitted result");
    } else {
      console.log("Failed to submit result");
    }
    return true;
  } catch (error) {
    console.error("Error submitting result:", error)
    return false;
  }
}

// Initialize and start the LLM service
async function initialize() {
  try {
    // retrieve chain and account info
    chainIdHash = await aergo.getChainIdHash();
    account = await aergo.getState(identity.address);

    // fetch this node's index from the contract (may not be authorized yet)
    await fetch_node_index();

    // initialize contract event handling (listens for new_request, node_added, node_removed)
    await initialize_event_handling(aergo, contract_address, on_contract_event);

    console.log("LLM service initialized and listening for events");
    if (myNodeIndex === -1) {
      console.log("Waiting for this node to be authorized...");
      console.log("Node address:", identity.address);
    }
  } catch (error) {
    console.error("Initialization error:", error);
    process.exit(1);
  }
}

// Start the LLM service
initialize();
