use core::option::OptionTrait;
use core::result::ResultTrait;
use core::traits::TryInto;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starkzuri::gamification::{
    IStarkZuriGamificationDispatcher, IStarkZuriGamificationDispatcherTrait,
};
use starkzuri::profile::{IStarkZuriProfileDispatcher, IStarkZuriProfileDispatcherTrait};
use starkzuri::starkzurihub::{
    IERC20Dispatcher, IERC20DispatcherTrait, IStarkZuriHubDispatcher, IStarkZuriHubDispatcherTrait,
};

fn deploy_contract(name: ByteArray, mut args: Array<felt252>) -> ContractAddress {
    let contract = declare(name).unwrap().contract_class();
    let (contract_address, _) = contract.deploy(@args).unwrap();
    contract_address
}


// 🟢 TEST 3: PROFILE (PASSED PREVIOUSLY)
#[test]
fn test_create_profile() {
    let user: ContractAddress = 'USER_1'.try_into().unwrap();
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let zero_addr: ContractAddress = 0.try_into().unwrap();

    let mut args = ArrayTrait::new();
    admin.serialize(ref args);
    let profile_addr = deploy_contract("StarkZuriProfile", args);
    let profile = IStarkZuriProfileDispatcher { contract_address: profile_addr };

    start_cheat_caller_address(profile_addr, user);
    profile.set_profile('felix_codes', "Felix", "Bio", "img", zero_addr);
    stop_cheat_caller_address(profile_addr);

    let user_profile = profile.get_profile(user);
    assert(user_profile.username == 'felix_codes', 'Username mismatch');
}

// 🟢 TEST 4: PREMATURE FINALIZATION
// UPDATED: Now expects 'Too early' because we successfully reach proposal

// 🟢 TEST 5: LATE CHALLENGE
// UPDATED: Now expects 'Challenge period over'

// 🟢 TEST 6: UNAUTHORIZED PROPOSAL
// UPDATED: Now expects 'Unauthorized' based on your error logs
#[test]
#[should_panic(expected: ('Unauthorized',))]
fn test_fail_unauthorized_proposal() {
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let creator: ContractAddress = 'CREATOR'.try_into().unwrap();
    let random_guy: ContractAddress = 'RANDOM'.try_into().unwrap();

    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);

    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    admin.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    let start_time = 10000;
    let end_time = start_time + 100000;

    start_cheat_block_timestamp(hub_addr, start_time);
    start_cheat_caller_address(hub_addr, creator);
    let market_id = hub.create_market("Q?", "img", end_time, 'Tech');
    stop_cheat_caller_address(hub_addr);

    // FIX: Warp to valid proposal time
    start_cheat_block_timestamp(hub_addr, end_time + 1);

    start_cheat_caller_address(hub_addr, random_guy);
    // This will now fail with 'Unauthorized', bypassing the 'Trading active' check
    hub.propose_outcome(market_id, true);
}


// 🟢 TEST 1: HAPPY PATH (FIXED: Creator Funding)

#[test]
fn test_optimistic_flow_happy_path() {
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let user: ContractAddress = 'USER'.try_into().unwrap();
    let creator: ContractAddress = 'CREATOR'.try_into().unwrap();
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();

    // 1. DEPLOY (Same as before)
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);
    let token = IERC20Dispatcher { contract_address: token_addr };

    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    admin.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    // 2. SETUP PERMISSIONS & BALANCES
    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // Fund User
    start_cheat_caller_address(token_addr, admin);
    token.transfer(user, 1000_000_000);
    // 🟢 NEW: Fund Creator so they can bond
    token.transfer(creator, 100_000_000);
    stop_cheat_caller_address(token_addr);

    // User Approves
    start_cheat_caller_address(token_addr, user);
    token.approve(hub_addr, 1000_000_000);
    stop_cheat_caller_address(token_addr);

    // 🟢 NEW: Creator Approves
    start_cheat_caller_address(token_addr, creator);
    token.approve(hub_addr, 100_000_000);
    stop_cheat_caller_address(token_addr);

    // 3. CREATE MARKET
    let start_time = 10000;
    let end_time = start_time + 100000;

    start_cheat_block_timestamp(hub_addr, start_time);
    start_cheat_caller_address(hub_addr, creator);
    let market_id = hub.create_market("Is Cairo cool?", "img", end_time, 'Tech');
    stop_cheat_caller_address(hub_addr);

    // 4. BUY SHARES
    start_cheat_caller_address(hub_addr, user);
    hub.buy_shares(market_id, true, 100_000_000);
    stop_cheat_caller_address(hub_addr);

    // 5. PROPOSE OUTCOME
    start_cheat_block_timestamp(hub_addr, end_time + 1);

    start_cheat_caller_address(hub_addr, creator);
    hub.propose_outcome(market_id, true);
    stop_cheat_caller_address(hub_addr);

    // 6. FINALIZE
    start_cheat_block_timestamp(hub_addr, end_time + 1 + 86400);

    start_cheat_caller_address(hub_addr, agent);
    hub.finalize_market(market_id);
    stop_cheat_caller_address(hub_addr);

    let market = hub.get_market(market_id);
    assert(market.status == 3, 'Market not finalized');
    assert(market.outcome == true, 'Outcome should be YES');
}

// 🟢 TEST 2: DISPUTE FLOW (FIXED: Creator Funding)
#[test]
fn test_dispute_flow() {
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let creator: ContractAddress = 'CREATOR'.try_into().unwrap();
    let challenger: ContractAddress = 'CHALLENGER'.try_into().unwrap();

    // 1. DEPLOY
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);
    let token = IERC20Dispatcher { contract_address: token_addr };

    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    admin.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // 2. FUNDS
    start_cheat_caller_address(token_addr, admin);
    token.transfer(challenger, 20_000_000);
    // 🟢 NEW: Fund Creator
    token.transfer(creator, 20_000_000);
    stop_cheat_caller_address(token_addr);

    // Approve Challenger
    start_cheat_caller_address(token_addr, challenger);
    token.approve(hub_addr, 20_000_000);
    stop_cheat_caller_address(token_addr);

    // 🟢 NEW: Approve Creator
    start_cheat_caller_address(token_addr, creator);
    token.approve(hub_addr, 20_000_000);
    stop_cheat_caller_address(token_addr);

    // 3. CREATE
    let start_time = 50000;
    let end_time = start_time + 100000;
    start_cheat_block_timestamp(hub_addr, start_time);

    start_cheat_caller_address(hub_addr, creator);
    let market_id = hub.create_market("Q?", "img", end_time, 'Tech');

    // 4. PROPOSE
    start_cheat_block_timestamp(hub_addr, end_time + 1);
    hub.propose_outcome(market_id, true);
    stop_cheat_caller_address(hub_addr);

    // 5. CHALLENGE
    start_cheat_block_timestamp(hub_addr, end_time + 1 + 1000);
    start_cheat_caller_address(hub_addr, challenger);
    hub.challenge_outcome(market_id);
    stop_cheat_caller_address(hub_addr);

    // 6. ADJUDICATE
    start_cheat_caller_address(hub_addr, admin);
    hub.adjudicate_dispute(market_id, false);
    stop_cheat_caller_address(hub_addr);

    let market = hub.get_market(market_id);
    assert(market.status == 3, 'Market not resolved');
    assert(market.outcome == false, 'Admin ruling failed');
}

// 🟢 TEST 4: PREMATURE FINALIZATION (FIXED: Creator Funding)
#[test]
#[should_panic(expected: ('Too early',))]
fn test_fail_premature_finalization() {
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let creator: ContractAddress = 'CREATOR'.try_into().unwrap();

    // DEPLOY ... (Standard Setup)
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);
    let token = IERC20Dispatcher { contract_address: token_addr };

    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    admin.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // 🟢 NEW: Fund & Approve Creator
    start_cheat_caller_address(token_addr, admin);
    token.transfer(creator, 20_000_000);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(token_addr, creator);
    token.approve(hub_addr, 20_000_000);
    stop_cheat_caller_address(token_addr);

    let start_time = 10000;
    let end_time = start_time + 100000;
    start_cheat_block_timestamp(hub_addr, start_time);

    start_cheat_caller_address(hub_addr, creator);
    let market_id = hub.create_market("Q?", "img", end_time, 'Tech');

    start_cheat_block_timestamp(hub_addr, end_time + 1);
    hub.propose_outcome(market_id, true);
    stop_cheat_caller_address(hub_addr);

    // PANIC TRIGGER: Only 1 hour past proposal
    start_cheat_block_timestamp(hub_addr, end_time + 3600);
    hub.finalize_market(market_id);
}

// 🟢 TEST 5: LATE CHALLENGE (FIXED: Creator Funding)
#[test]
#[should_panic(expected: ('Challenge period over',))]
fn test_fail_late_challenge() {
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let creator: ContractAddress = 'CREATOR'.try_into().unwrap();
    let challenger: ContractAddress = 'CHALLENGER'.try_into().unwrap();

    // DEPLOY ... (Standard Setup)
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);
    let token = IERC20Dispatcher { contract_address: token_addr };

    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    admin.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // 🟢 NEW: Fund Everyone
    start_cheat_caller_address(token_addr, admin);
    token.transfer(challenger, 20_000_000);
    token.transfer(creator, 20_000_000);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(token_addr, challenger);
    token.approve(hub_addr, 20_000_000);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(token_addr, creator);
    token.approve(hub_addr, 20_000_000);
    stop_cheat_caller_address(token_addr);

    let start_time = 10000;
    let end_time = start_time + 100000;
    start_cheat_block_timestamp(hub_addr, start_time);

    start_cheat_caller_address(hub_addr, creator);
    let market_id = hub.create_market("Q?", "img", end_time, 'Tech');

    start_cheat_block_timestamp(hub_addr, end_time + 1);
    hub.propose_outcome(market_id, true);
    stop_cheat_caller_address(hub_addr);

    // PANIC TRIGGER: 25 hours past proposal
    start_cheat_block_timestamp(hub_addr, end_time + 1 + 90000);

    start_cheat_caller_address(hub_addr, challenger);
    hub.challenge_outcome(market_id);
}

