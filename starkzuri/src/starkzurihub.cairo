use starknet::ContractAddress;
use starknet::class_hash::ClassHash;
use starknet::syscalls::replace_class_syscall;
use super::gamification::{IStarkZuriGamificationDispatcher, IStarkZuriGamificationDispatcherTrait};

#[starknet::interface]
pub trait IERC20<TContractState> {
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}

#[starknet::interface]
pub trait IStarkZuriHub<TContractState> {
    fn create_market(
        ref self: TContractState,
        question_uri: ByteArray,
        media_uri: ByteArray,
        deadline: u64,
        category: felt252,
    ) -> u64;


    fn buy_shares(
        ref self: TContractState, market_id: u64, is_yes: bool, investment_amount: u256,
    ) -> u256;
    fn sell_shares(
        ref self: TContractState, market_id: u64, is_yes: bool, share_amount: u256,
    ) -> u256;
    fn claim_winnings(ref self: TContractState, market_id: u64);
    fn resolve_market(ref self: TContractState, market_id: u64, outcome: bool);
    fn get_market(self: @TContractState, market_id: u64) -> Market;
    fn get_position(self: @TContractState, market_id: u64, user: ContractAddress) -> UserPosition;
    // NEW: Upgrade Function
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);

    // NEW: Read version
    fn get_version(self: @TContractState) -> u64;
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Market {
    pub id: u64,
    pub creator: ContractAddress,
    pub question_uri: ByteArray,
    pub media_uri: ByteArray,
    pub category: felt252,
    pub deadline: u64,
    pub virtual_yes_pool: u256,
    pub virtual_no_pool: u256,
    pub total_yes_shares_real: u256,
    pub total_no_shares_real: u256,
    pub total_pot_usdc: u256,
    pub status: u8,
    pub outcome: bool,
    pub resolution_time: u64,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct UserPosition {
    pub yes_shares: u256,
    pub no_shares: u256,
    pub has_claimed: bool,
}

#[starknet::contract]
mod StarkZuriHub {
    // FIX 4: Import Zero trait so .is_non_zero() works
    use core::num::traits::Zero;
    use starknet::class_hash::ClassHash;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait, IStarkZuriGamificationDispatcher,
        IStarkZuriGamificationDispatcherTrait, Market, UserPosition,
    };

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MarketCreated: MarketCreated,
        TradeExecuted: TradeExecuted,
        MarketStatusChanged: MarketStatusChanged,
        WinningsClaimed: WinningsClaimed,
        Upgraded: Upgraded,
    }

    #[derive(Drop, starknet::Event)]
    struct MarketCreated {
        #[key]
        market_id: u64,
        #[key]
        creator: ContractAddress,
        #[key]
        category: felt252,
        question_uri: ByteArray,
        media_uri: ByteArray,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct TradeExecuted {
        #[key]
        market_id: u64,
        #[key]
        user: ContractAddress,
        action: felt252,
        is_yes: bool,
        amount_usdc: u256,
        shares: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Upgraded {
        implementation: ClassHash,
    }

    #[derive(Drop, starknet::Event)]
    struct MarketStatusChanged {
        #[key]
        market_id: u64,
        new_status: u8,
        outcome: bool,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct WinningsClaimed {
        #[key]
        market_id: u64,
        #[key]
        user: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[storage]
    struct Storage {
        market_count: u64,
        markets: Map<u64, Market>,
        positions: Map<u64, Map<ContractAddress, UserPosition>>,
        usdc_token: ContractAddress,
        oracle_agent: ContractAddress,
        gamification_contract: ContractAddress,
        admin: ContractAddress, // The "Felix" address
        version: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        usdc_address: ContractAddress,
        agent_address: ContractAddress,
        gamification_address: ContractAddress,
        admin_address: ContractAddress,
    ) {
        self.usdc_token.write(usdc_address);
        self.oracle_agent.write(agent_address);
        self.gamification_contract.write(gamification_address);
        self.market_count.write(0);

        self.admin.write(admin_address);
        self.version.write(1);
    }

    #[abi(embed_v0)]
    impl StarkZuriHubImpl of super::IStarkZuriHub<ContractState> {
        fn create_market(
            ref self: ContractState,
            question_uri: ByteArray,
            media_uri: ByteArray,
            deadline: u64,
            category: felt252,
        ) -> u64 {
            let caller = get_caller_address();
            let now = get_block_timestamp();

            assert(deadline > now, 'Deadline must be future');

            let new_id = self.market_count.read() + 1;
            let phantom_liquidity = 1_000_000_000_u256;

            let market = Market {
                id: new_id,
                creator: caller,
                question_uri: question_uri.clone(),
                media_uri: media_uri.clone(),
                category: category,
                deadline: deadline,
                virtual_yes_pool: phantom_liquidity,
                virtual_no_pool: phantom_liquidity,
                total_yes_shares_real: 0,
                total_no_shares_real: 0,
                total_pot_usdc: 0,
                status: 0,
                outcome: false,
                resolution_time: 0,
            };

            self.markets.entry(new_id).write(market);
            self.market_count.write(new_id);

            let game_addr = self.gamification_contract.read();
            if game_addr.is_non_zero() {
                IStarkZuriGamificationDispatcher { contract_address: game_addr }
                    .register_action(caller, 'CREATE_MARKET');
            }

            self
                .emit(
                    MarketCreated {
                        market_id: new_id,
                        creator: caller,
                        category: category,
                        question_uri: question_uri,
                        media_uri: media_uri,
                        timestamp: now,
                    },
                );

            return new_id;
        }

        fn buy_shares(
            ref self: ContractState, market_id: u64, is_yes: bool, investment_amount: u256,
        ) -> u256 {
            let caller = get_caller_address();
            let mut market = self.markets.entry(market_id).read();

            assert(market.status == 0, 'Market not active');
            assert(get_block_timestamp() < market.deadline, 'Trading closed');

            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
            let success = usdc.transferFrom(caller, get_contract_address(), investment_amount);
            assert(success, 'USDC Transfer failed');

            let total_virtual = market.virtual_yes_pool + market.virtual_no_pool;
            let price_probability = if is_yes {
                (market.virtual_yes_pool * 1_000_000) / total_virtual
            } else {
                (market.virtual_no_pool * 1_000_000) / total_virtual
            };

            let shares_out = (investment_amount * 1_000_000) / price_probability;
            assert(shares_out > 0, 'Investment too small');

            market.total_pot_usdc += investment_amount;
            if is_yes {
                market.virtual_yes_pool += investment_amount;
                market.total_yes_shares_real += shares_out;
            } else {
                market.virtual_no_pool += investment_amount;
                market.total_no_shares_real += shares_out;
            }

            let mut pos = self.positions.entry(market_id).entry(caller).read();
            if is_yes {
                pos.yes_shares += shares_out;
            } else {
                pos.no_shares += shares_out;
            }

            self.positions.entry(market_id).entry(caller).write(pos);
            self.markets.entry(market_id).write(market);

            let game_addr = self.gamification_contract.read();
            if game_addr.is_non_zero() {
                IStarkZuriGamificationDispatcher { contract_address: game_addr }
                    .register_action(caller, 'TRADE');
            }

            self
                .emit(
                    TradeExecuted {
                        market_id: market_id,
                        user: caller,
                        action: 'BUY',
                        is_yes: is_yes,
                        amount_usdc: investment_amount,
                        shares: shares_out,
                        timestamp: get_block_timestamp(),
                    },
                );

            shares_out
        }

        fn sell_shares(
            ref self: ContractState, market_id: u64, is_yes: bool, share_amount: u256,
        ) -> u256 {
            let caller = get_caller_address();
            let mut market = self.markets.entry(market_id).read();
            let mut pos = self.positions.entry(market_id).entry(caller).read();

            assert(market.status == 0, 'Market not active');

            let total_virtual = market.virtual_yes_pool + market.virtual_no_pool;
            let payout = if is_yes {
                assert(pos.yes_shares >= share_amount, 'Insufficient YES shares');
                let val = (share_amount * market.virtual_yes_pool) / total_virtual;
                market.virtual_yes_pool -= val;
                market.total_yes_shares_real -= share_amount;
                market.total_pot_usdc -= val;
                pos.yes_shares -= share_amount;
                val
            } else {
                assert(pos.no_shares >= share_amount, 'Insufficient NO shares');
                let val = (share_amount * market.virtual_no_pool) / total_virtual;
                market.virtual_no_pool -= val;
                market.total_no_shares_real -= share_amount;
                market.total_pot_usdc -= val;
                pos.no_shares -= share_amount;
                val
            };

            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
            usdc.transfer(caller, payout);

            self.positions.entry(market_id).entry(caller).write(pos);
            self.markets.entry(market_id).write(market);

            self
                .emit(
                    TradeExecuted {
                        market_id: market_id,
                        user: caller,
                        action: 'SELL',
                        is_yes: is_yes,
                        amount_usdc: payout,
                        shares: share_amount,
                        timestamp: get_block_timestamp(),
                    },
                );

            return payout;
        }

        fn resolve_market(ref self: ContractState, market_id: u64, outcome: bool) {
            let caller = get_caller_address();
            assert(caller == self.oracle_agent.read(), 'Unauthorized Agent');
            let mut market = self.markets.entry(market_id).read();
            assert(market.status == 0, 'Already resolved');
            market.status = 3;
            market.outcome = outcome;
            market.resolution_time = get_block_timestamp();
            self.markets.entry(market_id).write(market);
            self
                .emit(
                    MarketStatusChanged {
                        market_id: market_id,
                        new_status: 3,
                        outcome: outcome,
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        fn claim_winnings(ref self: ContractState, market_id: u64) {
            let caller = get_caller_address();
            let market = self.markets.entry(market_id).read();
            assert(market.status == 3, 'Not Finalized');

            let mut pos = self.positions.entry(market_id).entry(caller).read();
            assert(!pos.has_claimed, 'Already claimed');

            let mut payout: u256 = 0;
            if market.outcome == true {
                if market.total_yes_shares_real > 0 {
                    payout = (pos.yes_shares * market.total_pot_usdc)
                        / market.total_yes_shares_real;
                }
            } else {
                if market.total_no_shares_real > 0 {
                    payout = (pos.no_shares * market.total_pot_usdc) / market.total_no_shares_real;
                }
            }

            pos.has_claimed = true;
            self.positions.entry(market_id).entry(caller).write(pos);

            if payout > 0 {
                let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
                usdc.transfer(caller, payout);
            }

            self
                .emit(
                    WinningsClaimed {
                        market_id: market_id,
                        user: caller,
                        amount: payout,
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        fn get_market(self: @ContractState, market_id: u64) -> Market {
            self.markets.entry(market_id).read()
        }

        fn get_position(
            self: @ContractState, market_id: u64, user: ContractAddress,
        ) -> UserPosition {
            self.positions.entry(market_id).entry(user).read()
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            let caller = get_caller_address();
            let admin = self.admin.read();

            // The "Only Felix" check
            assert(caller == admin, 'Only Admin can upgrade');

            // Assert hash is valid (non-zero check is good practice)
            assert(impl_hash.is_non_zero(), 'Class hash cannot be zero');

            // The System Call that swaps the code
            replace_class_syscall(impl_hash).unwrap();

            // Update State
            self.version.write(self.version.read() + 1);

            self.emit(Upgraded { implementation: impl_hash });
        }

        fn get_version(self: @ContractState) -> u64 {
            self.version.read()
        }
    }
}

