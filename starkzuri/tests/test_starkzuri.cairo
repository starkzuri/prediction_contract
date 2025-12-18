use core::option::OptionTrait;
use core::result::ResultTrait;
use core::traits::TryInto;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
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

#[test]
fn test_full_market_flow_with_xp() {
    // 1. SETUP ADDRESSES
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let user: ContractAddress = 'USER'.try_into().unwrap();
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();

    // 2. DEPLOY GAMIFICATION
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args); // Admin is Owner
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    // 3. DEPLOY MOCK USDC
    let mut token_args = ArrayTrait::new();
    let name: ByteArray = "USDC";
    let symbol: ByteArray = "USDC";
    name.serialize(ref token_args);
    symbol.serialize(ref token_args);
    1_000_000_000_000_u256.serialize(ref token_args);
    admin.serialize(ref token_args);
    let token_addr = deploy_contract("MockERC20", token_args);
    let token = IERC20Dispatcher { contract_address: token_addr };

    // 4. DEPLOY HUB (With Game Address)
    let mut hub_args = ArrayTrait::new();
    token_addr.serialize(ref hub_args);
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args); // Pass Game Addr
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    // 5. AUTHORIZE THE HUB
    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // 6. FUND & APPROVE USER
    start_cheat_caller_address(token_addr, admin);
    token.transfer(user, 1000_000_000);
    stop_cheat_caller_address(token_addr);

    start_cheat_caller_address(token_addr, user);
    token.approve(hub_addr, 1000_000_000);
    stop_cheat_caller_address(token_addr);

    // 7. CREATE MARKET (Triggers XP)
    start_cheat_caller_address(hub_addr, user);
    hub.create_market("Q?", "img", 2000000000, 'Crypto');

    // 8. BUY SHARES (Triggers XP)
    hub.buy_shares(1, true, 100_000_000);
    stop_cheat_caller_address(hub_addr);

    // 9. VERIFY XP WAS AWARDED
    let stats = game.get_user_stats(user);
    // 100 XP (Create) + 50 XP (Trade) = 150 XP
    assert(stats.total_xp == 150, 'XP Calculation Wrong');
    assert(stats.trades_count == 1, 'Trade count wrong');
}

// // SAD PATH 2: Unauthorized Resolution
// // We expect this to FAIL with 'Unauthorized Agent'
// #[test]
// #[should_panic(expected: ('Unauthorized Agent',))]
// fn test_fail_unauthorized_resolution() {
//     // 1. Setup
//     let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
//     let hacker: ContractAddress = 'HACKER'.try_into().unwrap(); // Not the Agent!
//     let agent: ContractAddress = 'AGENT'.try_into().unwrap();

//     // 1b. Deploy Dummy Gamification (Hub needs it in constructor now)
//     let mut game_args = ArrayTrait::new();
//     admin.serialize(ref game_args);
//     let game_addr = deploy_contract("StarkZuriGamification", game_args);

//     // Deploy
//     let mut token_args = ArrayTrait::new();
//     let name: ByteArray = "USDC";
//     let symbol: ByteArray = "USDC";
//     name.serialize(ref token_args);
//     symbol.serialize(ref token_args);
//     1_000_000_000_000_u256.serialize(ref token_args);
//     admin.serialize(ref token_args);
//     let token_addr = deploy_contract("MockERC20", token_args);

//     let mut hub_args = ArrayTrait::new();
//     token_addr.serialize(ref hub_args);
//     agent.serialize(ref hub_args);
//     game_addr.serialize(ref hub_args); // FIX: Pass game addr
//     let hub_addr = deploy_contract("StarkZuriHub", hub_args);
//     let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

//     // 2. Create Market
//     start_cheat_caller_address(hub_addr, admin);
//     let market_id = hub.create_market("Q?", "img", 2000000000, 'Crypto');
//     stop_cheat_caller_address(hub_addr);

//     // 3. THE ATTACK: Hacker tries to resolve the market
//     start_cheat_caller_address(hub_addr, hacker);

//     // This should panic because hacker != agent
//     hub.resolve_market(market_id, true);

//     stop_cheat_caller_address(hub_addr);
// }

// SAD PATH 2: Unauthorized Resolution
// We expect this to FAIL with 'Unauthorized Agent'
#[test]
#[should_panic(expected: ('Unauthorized Agent',))]
fn test_fail_unauthorized_resolution() {
    // 1. Setup
    let admin: ContractAddress = 'ADMIN'.try_into().unwrap();
    let hacker: ContractAddress = 'HACKER'.try_into().unwrap(); // Not the Agent!
    let agent: ContractAddress = 'AGENT'.try_into().unwrap();

    // 1a. Deploy Gamification
    let mut game_args = ArrayTrait::new();
    admin.serialize(ref game_args);
    let game_addr = deploy_contract("StarkZuriGamification", game_args);
    // Need dispatcher to authorize hub
    let game = IStarkZuriGamificationDispatcher { contract_address: game_addr };

    // 1b. Deploy Token & Hub
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
    agent.serialize(ref hub_args);
    game_addr.serialize(ref hub_args);
    let hub_addr = deploy_contract("StarkZuriHub", hub_args);
    let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

    // 1c. FIX: AUTHORIZE THE HUB (So create_market doesn't crash)
    start_cheat_caller_address(game_addr, admin);
    game.set_controller(hub_addr, true);
    stop_cheat_caller_address(game_addr);

    // 2. Create Market (Now this will succeed!)
    start_cheat_caller_address(hub_addr, admin);
    let market_id = hub.create_market("Q?", "img", 2000000000, 'Crypto');
    stop_cheat_caller_address(hub_addr);

    // 3. THE ATTACK: Hacker tries to resolve the market
    start_cheat_caller_address(hub_addr, hacker);

    // This should panic because hacker != agent
    // AND it will match the expected error 'Unauthorized Agent'
    hub.resolve_market(market_id, true);

    stop_cheat_caller_address(hub_addr);
}

// ============================================================================
//                              PROFILE TESTS
// ============================================================================

#[test]
fn test_create_profile_happy_path() {
    // 1. Setup
    let user: ContractAddress = 'USER_1'.try_into().unwrap();
    let zero_addr: ContractAddress = 0.try_into().unwrap();

    // Deploy Profile (No constructor args needed)
    let profile_addr = deploy_contract("StarkZuriProfile", ArrayTrait::new());
    let profile = IStarkZuriProfileDispatcher { contract_address: profile_addr };

    // 2. Act: User sets profile
    start_cheat_caller_address(profile_addr, user);

    profile
        .set_profile(
            'felix_codes', // Username (felt252)
            "Felix", // Display Name
            "Building Starknet", // Bio
            "ipfs://my_avatar", // Avatar
            zero_addr // No referrer
        );

    stop_cheat_caller_address(profile_addr);

    // 3. Assert: Check if data was saved
    let user_profile = profile.get_profile(user);
    assert(user_profile.username == 'felix_codes', 'Username mismatch');
    assert(user_profile.is_registered == true, 'Should be registered');

    // 4. Assert: Reverse lookup (Username -> Address)
    let looked_up_addr = profile.get_address_from_username('felix_codes');
    assert(looked_up_addr == user, 'Reverse lookup failed');
}

#[test]
#[should_panic(expected: ('Username already taken',))]
fn test_fail_duplicate_username() {
    // 1. Setup
    let user1: ContractAddress = 'USER_1'.try_into().unwrap();
    let user2: ContractAddress = 'COPYCAT'.try_into().unwrap();
    let zero_addr: ContractAddress = 0.try_into().unwrap();

    let profile_addr = deploy_contract("StarkZuriProfile", ArrayTrait::new());
    let profile = IStarkZuriProfileDispatcher { contract_address: profile_addr };

    // 2. User 1 claims "king"
    start_cheat_caller_address(profile_addr, user1);
    profile.set_profile('king', "The King", "", "", zero_addr);
    stop_cheat_caller_address(profile_addr);

    // 3. User 2 tries to claim "king" -> SHOULD PANIC
    start_cheat_caller_address(profile_addr, user2);
    profile.set_profile('king', "Imposter", "", "", zero_addr);
    stop_cheat_caller_address(profile_addr);
}

#[test]
fn test_referral_system_works() {
    // 1. Setup
    let referrer: ContractAddress = 'OG_USER'.try_into().unwrap();
    let newbie: ContractAddress = 'NEWBIE'.try_into().unwrap();
    let zero_addr: ContractAddress = 0.try_into().unwrap();

    let profile_addr = deploy_contract("StarkZuriProfile", ArrayTrait::new());
    let profile = IStarkZuriProfileDispatcher { contract_address: profile_addr };

    // 2. Register the Referrer first (Must be registered to receive referrals)
    start_cheat_caller_address(profile_addr, referrer);
    profile.set_profile('og_user', "OG", "", "", zero_addr);
    stop_cheat_caller_address(profile_addr);

    // 3. Register the Newbie AND pass the Referrer's address
    start_cheat_caller_address(profile_addr, newbie);
    profile.set_profile('new_guy', "New Guy", "", "", referrer);
    stop_cheat_caller_address(profile_addr);

    // 4. Assert: Check if Referrer got the point
    let count = profile.get_referral_count(referrer);
    assert(count == 1, 'Referral count should be 1');

    // 5. Assert: Check if Newbie has the correct referrer stored
    let newbie_profile = profile.get_profile(newbie);
    assert(newbie_profile.referrer == referrer, 'Referrer not linked');
}
