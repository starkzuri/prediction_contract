// #[starknet::interface]
// trait IERC20<TContractState> {
//     fn transferFrom(
//         ref self: TContractState,
//         sender: starknet::ContractAddress,
//         recipient: starknet::ContractAddress,
//         amount: u256,
//     ) -> bool;
//     fn transfer(
//         ref self: TContractState, recipient: starknet::ContractAddress, amount: u256,
//     ) -> bool;
//     fn balanceOf(self: @TContractState, account: starknet::ContractAddress) -> u256;
//     fn approve(ref self: TContractState, spender: starknet::ContractAddress, amount: u256) ->
//     bool;
// }

// #[cfg(test)]
// mod tests {
//     use snforge_std::{
//         ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address, start_prank,
//         stop_cheat_caller_address, stop_prank,
//     };
//     use starknet::{ContractAddress, contract_address_const};

//     // Import your contract interfaces
//     use starkzuri::IStarkZuriHubDispatcher;
//     use starkzuri::{IERC20Dispatcher, IERC20DispatcherTrait, IStarkZuriHubDispatcherTrait};

//     // --- 1. Helper to Deploy the Hub ---
//     fn deploy_hub(usdc_address: ContractAddress, agent: ContractAddress) -> ContractAddress {
//         let contract = declare("StarkZuriHub").unwrap().contract_class();

//         // Serialize constructor args
//         let mut calldata = ArrayTrait::new();
//         usdc_address.serialize(ref calldata);
//         agent.serialize(ref calldata);

//         let (contract_address, _) = contract.deploy(@calldata).unwrap();
//         contract_address
//     }

//     // --- 2. Helper to Deploy a Mock Token (USDC) ---
//     // You need a simple ERC20 contract in your src/ or tests/mocks folder for this to work.
//     // If you don't have one, snforge can mock the calls, but deploying is cleaner.
//     // Assuming you have a contract named "MockToken" defined somewhere.
//     // If not, we will assume standard mocking logic below.

//     // For this test, let's assume we deploy a "MockERC20"
//     fn deploy_mock_token() -> ContractAddress {
//         let contract = declare("MockERC20").unwrap().contract_class();
//         let mut calldata = ArrayTrait::new();
//         // Mock Constructor: name, symbol, initial_supply, recipient
//         "USDC".serialize(ref calldata);
//         "USDC".serialize(ref calldata);
//         1_000_000_000_000_u256.serialize(ref calldata); // Mint huge supply
//         let admin = contract_address_const::<'ADMIN'>();
//         admin.serialize(ref calldata);

//         let (address, _) = contract.deploy(@calldata).unwrap();
//         return address;
//     }

//     #[test]
//     fn test_create_market() {
//         // Setup
//         let mock_usdc = deploy_mock_token();
//         let agent = contract_address_const::<'AGENT'>();
//         let hub_address = deploy_hub(mock_usdc, agent);
//         let dispatcher = IStarkZuriHubDispatcher { contract_address: hub_address };

//         // Test Data
//         let question = "Will BTC hit 100k?";
//         let media = "";
//         let deadline = 2000000000; // Future timestamp
//         let category = 'Crypto';

//         // Act
//         start_prank(hub_address, contract_address_const::<'CREATOR'>());
//         let market_id = dispatcher.create_market(question, media, deadline, category);
//         stop_prank(hub_address);

//         // Assert
//         assert(market_id == 1, 'Market ID should be 1');

//         let market = dispatcher.get_market(1);
//         assert(market.id == 1, 'ID mismatch');
//         assert(market.virtual_yes_pool == 1_000_000_000, 'Virtual Liquidity wrong');
//         assert(market.total_pot_usdc == 0, 'Real Pot should be 0');
//     }

//     #[test]
//     fn test_buy_shares() {
//         // Setup
//         let mock_usdc_addr = deploy_mock_token();
//         let usdc = IERC20Dispatcher { contract_address: mock_usdc_addr };

//         let agent = contract_address_const::<'AGENT'>();
//         let hub_addr = deploy_hub(mock_usdc_addr, agent);
//         let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };

//         let user = contract_address_const::<'USER'>();
//         let admin = contract_address_const::<'ADMIN'>(); // Minted tokens here in mock

//         // 1. Transfer USDC to User & Approve Hub
//         start_prank(mock_usdc_addr, admin);
//         usdc.transfer(user, 1000_000_000); // Give user 1000 USDC
//         stop_prank(mock_usdc_addr);

//         start_prank(mock_usdc_addr, user);
//         usdc.approve(hub_addr, 1000_000_000);
//         stop_prank(mock_usdc_addr);

//         // 2. Create Market
//         start_prank(hub_addr, user);
//         hub.create_market("Q?", "", 9999999999, 'Tech');

//         // 3. Buy YES Shares (Invest 100 USDC)
//         let investment = 100_000_000_u256; // 100 USDC (6 decimals implied)
//         let shares = hub.buy_shares(1, true, investment);

//         stop_prank(hub_addr);

//         // Assertions
//         let market = hub.get_market(1);

//         // Virtual pool should increase
//         assert(market.virtual_yes_pool > 1_000_000_000, 'Virtual pool did not grow');
//         // Real pot should have money
//         assert(market.total_pot_usdc == investment, 'Pot is missing funds');

//         // User position
//         let pos = hub.get_position(1, user);
//         assert(pos.yes_shares == shares, 'Position not updated');
//         assert(shares > 0, 'Shares should be > 0');
//     }

//     #[test]
//     fn test_sell_shares() {
//         // Setup (Identical to buy)
//         let mock_usdc_addr = deploy_mock_token();
//         let usdc = IERC20Dispatcher { contract_address: mock_usdc_addr };
//         let agent = contract_address_const::<'AGENT'>();
//         let hub_addr = deploy_hub(mock_usdc_addr, agent);
//         let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };
//         let user = contract_address_const::<'USER'>();
//         let admin = contract_address_const::<'ADMIN'>();

//         // Fund User
//         start_prank(mock_usdc_addr, admin);
//         usdc.transfer(user, 1000_000_000);
//         stop_prank(mock_usdc_addr);
//         start_prank(mock_usdc_addr, user);
//         usdc.approve(hub_addr, 1000_000_000);
//         stop_prank(mock_usdc_addr);

//         // Buy
//         start_prank(hub_addr, user);
//         hub.create_market("Q?", "", 9999999999, 'Tech');
//         let investment = 100_000_000_u256;
//         let shares_bought = hub.buy_shares(1, true, investment);

//         // Act: Panic Sell Half
//         let shares_to_sell = shares_bought / 2;
//         let refund = hub.sell_shares(1, true, shares_to_sell);
//         stop_prank(hub_addr);

//         // Assert
//         let pos = hub.get_position(1, user);
//         assert(pos.yes_shares == shares_bought - shares_to_sell, 'Shares not deducted');
//         assert(refund > 0, 'Refund should be > 0');
//         assert(refund < investment, 'Refund should be less than total investment');
//     }

//     #[test]
//     fn test_resolve_and_claim() {
//         // Setup
//         let mock_usdc_addr = deploy_mock_token();
//         let usdc = IERC20Dispatcher { contract_address: mock_usdc_addr };
//         let agent = contract_address_const::<'AGENT'>();
//         let hub_addr = deploy_hub(mock_usdc_addr, agent);
//         let hub = IStarkZuriHubDispatcher { contract_address: hub_addr };
//         let winner = contract_address_const::<'WINNER'>();
//         let loser = contract_address_const::<'LOSER'>();
//         let admin = contract_address_const::<'ADMIN'>();

//         // Fund Both Users
//         start_prank(mock_usdc_addr, admin);
//         usdc.transfer(winner, 500_000_000);
//         usdc.transfer(loser, 500_000_000);
//         stop_prank(mock_usdc_addr);

//         // Approve
//         start_prank(mock_usdc_addr, winner);
//         usdc.approve(hub_addr, 500_000_000);
//         stop_prank(mock_usdc_addr);
//         start_prank(mock_usdc_addr, loser);
//         usdc.approve(hub_addr, 500_000_000);
//         stop_prank(mock_usdc_addr);

//         // Create Market
//         start_prank(hub_addr, admin);
//         hub.create_market("Q?", "", 9999999999, 'Tech');
//         stop_prank(hub_addr);

//         // Bets
//         start_prank(hub_addr, winner);
//         hub.buy_shares(1, true, 100_000_000); // Bets YES
//         stop_prank(hub_addr);

//         start_prank(hub_addr, loser);
//         hub.buy_shares(1, false, 100_000_000); // Bets NO
//         stop_prank(hub_addr);

//         // Act: Resolve YES as Winner
//         start_prank(hub_addr, agent);
//         hub.resolve_market(1, true);
//         stop_prank(hub_addr);

//         // Assert: Winner Claims
//         start_prank(hub_addr, winner);
//         let balance_before = usdc.balanceOf(winner);
//         hub.claim_winnings(1);
//         let balance_after = usdc.balanceOf(winner);
//         stop_prank(hub_addr);

//         assert(balance_after > balance_before, 'Winner got nothing');

//         // Assert: Loser Claims (Should fail or get 0)
//         // Since we didn't implement robust error handling in claim (it checks outcome),
//         // let's just check state logic or expectation.
//         // In our contract: if you have NO shares and YES won, payout is 0.
//         start_prank(hub_addr, loser);
//         let l_balance_before = usdc.balanceOf(loser);
//         hub.claim_winnings(1);
//         let l_balance_after = usdc.balanceOf(loser);
//         stop_prank(hub_addr);

//         assert(l_balance_after == l_balance_before, 'Loser should get 0');
//     }
// }
