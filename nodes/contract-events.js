const fs = require('fs');
const path = require('path');

const CONFIG_PATH = process.env.CONFIG_PATH || __dirname;

let block_height_update_timer = null;
let event_stream = null;
let is_active = true;

// Function to get file path for storing the last processed block
function get_last_processed_block_file_path(contract_address) {
  return path.join(CONFIG_PATH, contract_address + '.last-processed-block');
}

// Function to read last processed block from file
function get_last_processed_block(contract_address) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    const blockHeight = fs.readFileSync(filePath).toString();
    return parseInt(blockHeight);
  } catch (err) {
    return 0;
  }
}

// Function to write last processed block to file
function write_last_processed_block(contract_address, blockHeight) {
  try {
    const filePath = get_last_processed_block_file_path(contract_address);
    fs.writeFileSync(filePath, blockHeight.toString());
  } catch (err) {
    console.error('Error writing last processed block to file:', err);
  }
}

// Retrieve past events from the price oracle contract
async function get_past_events(aergo, contract_address, on_contract_event_callback) {
  let start_block = get_last_processed_block(contract_address);
  const last_block = await get_last_blockchain_block(aergo);

  if (start_block == 0) {
    return;
  }

  console.log("Reading past events of contract", contract_address, "from block", start_block, "to", last_block);

  while (start_block < last_block) {
    let end_block = start_block + 10000;
    if (end_block > last_block) end_block = 0;

    console.log("Fetching events from block", start_block, "to block", (end_block > 0 ? end_block : '(last)'));

    // Retrieve the events from this range
    const events = await aergo.getEvents({
      address: contract_address,
      blockfrom: start_block,
      blockto: end_block
    });

    // Sort the events by the block number
    events.sort((a, b) => a.blockno - b.blockno);

    // Process each event
    events.forEach(function(event) {
      if (!is_active) {
        return;
      }
      on_contract_event_callback(event, false);
    });

    if (!is_active) {
      return;
    }

    start_block += 10000;
  }

  // Update the last processed block
  write_last_processed_block(contract_address, last_block);
}

// Subscribe to new events from the price oracle contract
async function subscribe_to_events(aergo, contract_address, on_contract_event_callback) {
  console.log("Subscribing to new events from contract", contract_address, "...");

  event_stream = aergo.getEventStream({
    address: contract_address
  });

  event_stream.on('data', (event) => {
    if (!is_active) {
      return;
    }
    // Call the callback function
    on_contract_event_callback(event, true);
    // Update the last processed block
    write_last_processed_block(contract_address, event.blockno);
  });
}

// Get the last blockchain block
async function get_last_blockchain_block(aergo) {
  const blockchainState = await aergo.blockchain();
  return blockchainState.bestHeight;
}

// Update block height periodically
async function update_block_height(aergo, contract_address) {
  const blockchainState = await aergo.blockchain();
  console.log("Current block:", blockchainState.bestHeight);
  write_last_processed_block(contract_address, blockchainState.bestHeight);
  block_height_update_timer = setTimeout(() => {
    update_block_height(aergo, contract_address);
  }, 180 * 1000);  // 3 minutes
}

async function terminate_event_handling() {
  console.log("Terminating event handling...");
  is_active = false;
  if (block_height_update_timer) {
    clearTimeout(block_height_update_timer);
  }
  if (event_stream) {
    event_stream.cancel();
  }
}

async function initialize_event_handling(aergo, contract_address, on_contract_event_callback) {
  // Store the callback function
  if (typeof on_contract_event_callback !== 'function') {
    throw new Error('on_contract_event_callback must be a function');
  }

  // Get past events to update last_prices with any missed events
  await get_past_events(aergo, contract_address, on_contract_event_callback);

  // Subscribe to new events
  await subscribe_to_events(aergo, contract_address, on_contract_event_callback);

  // Start periodic block height updates
  update_block_height(aergo, contract_address);
}

module.exports = {
  initialize_event_handling,
  terminate_event_handling
};
