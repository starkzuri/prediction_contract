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

    // 🟢 NEW: OPTIMISTIC ORACLE INTERFACE
    fn propose_outcome(ref self: TContractState, market_id: u64, outcome: bool);
    fn challenge_outcome(ref self: TContractState, market_id: u64);
    fn finalize_market(ref self: TContractState, market_id: u64);
    fn adjudicate_dispute(ref self: TContractState, market_id: u64, outcome: bool);

    fn get_market(self: @TContractState, market_id: u64) -> Market;
    fn get_position(self: @TContractState, market_id: u64, user: ContractAddress) -> UserPosition;

    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
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
        // 🟢 NEW EVENTS
        OutcomeProposed: OutcomeProposed,
        OutcomeChallenged: OutcomeChallenged,
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
        deadline: u64,
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

    // 🟢 NEW EVENT STRUCTS
    #[derive(Drop, starknet::Event)]
    struct OutcomeProposed {
        #[key]
        market_id: u64,
        outcome: bool,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OutcomeChallenged {
        #[key]
        market_id: u64,
        challenger: ContractAddress,
        amount: u256,
    }

    #[storage]
    struct Storage {
        market_count: u64,
        markets: Map<u64, Market>,
        positions: Map<u64, Map<ContractAddress, UserPosition>>,
        usdc_token: ContractAddress,
        oracle_agent: ContractAddress,
        gamification_contract: ContractAddress,
        admin: ContractAddress,
        version: u64,
        // 🟢 NEW: OPTIMISTIC ORACLE STORAGE
        market_proposal: Map<u64, u8>, // 0=None, 1=NO, 2=YES
        proposal_timestamp: Map<u64, u64>, // 24h Timer start
        is_disputed: Map<u64, bool>, // Frozen?
        challenger: Map<u64, ContractAddress>, // Who challenged
        dispute_bond: Map<u64, u256> // Amount staked
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
                        deadline: deadline,
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

        // 🟢 1. PROPOSE OUTCOME (Starts 24h Timer)
        fn propose_outcome(ref self: ContractState, market_id: u64, outcome: bool) {
            let market = self.markets.entry(market_id).read();
            let caller = get_caller_address();
            let agent = self.oracle_agent.read();

            // 🟢 CONFIG: The Bond Amount ($10 USDC)
            let bond_amount: u256 = 10_000_000;

            // 1. Permission Check: Must be Creator OR Agent
            if caller != agent {
                assert(caller == market.creator, 'Unauthorized');
            }

            // 2. Status Checks
            assert(market.status == 0, 'Market already resolved');
            assert(self.proposal_timestamp.entry(market_id).read() == 0, 'Proposal already active');
            assert(get_block_timestamp() >= market.deadline, 'Trading still active');

            // 3. 🟢 THE DUAL PAYMENT LOGIC
            // If it is NOT the bot, we demand a bond.
            if caller != agent {
                let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };

                // Transfer Bond from Creator to Contract
                // (Creator must have approved the contract first)

                let success = usdc.transferFrom(caller, get_contract_address(), bond_amount);

                assert(success, 'Bond Transfer failed');

                // Record that we hold a bond for this market
                self.dispute_bond.entry(market_id).write(bond_amount);
            }

            // 4. Lock the Proposal
            let outcome_val = if outcome {
                2
            } else {
                1
            }; // 1=NO, 2=YES
            self.market_proposal.entry(market_id).write(outcome_val);
            self.proposal_timestamp.entry(market_id).write(get_block_timestamp());

            self
                .emit(
                    OutcomeProposed {
                        market_id: market_id, outcome: outcome, timestamp: get_block_timestamp(),
                    },
                );
        }

        // 🟢 2. CHALLENGE OUTCOME (Requires $10 Bond)
        fn challenge_outcome(ref self: ContractState, market_id: u64) {
            let caller = get_caller_address();
            let bond_amount: u256 = 10_000_000; // 10 USDC

            let proposal_ts = self.proposal_timestamp.entry(market_id).read();
            assert(proposal_ts > 0, 'No proposal exists');
            assert(!self.is_disputed.entry(market_id).read(), 'Already disputed');
            // 86400 seconds = 24 hours
            assert(get_block_timestamp() < proposal_ts + 86400, 'Challenge period over');

            // Take Bond
            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
            let success = usdc.transferFrom(caller, get_contract_address(), bond_amount);
            assert(success, 'Bond Transfer failed');

            // Lock Market
            self.is_disputed.entry(market_id).write(true);
            self.challenger.entry(market_id).write(caller);
            self.dispute_bond.entry(market_id).write(bond_amount);

            self
                .emit(
                    OutcomeChallenged {
                        market_id: market_id, challenger: caller, amount: bond_amount,
                    },
                );
        }

        // 🟢 3. FINALIZE (Resolves if 24h passed w/o challenge)
        fn finalize_market(ref self: ContractState, market_id: u64) {
            let proposal_ts = self.proposal_timestamp.entry(market_id).read();
            let is_disputed = self.is_disputed.entry(market_id).read();

            assert(proposal_ts > 0, 'No proposal to finalize');
            assert(!is_disputed, 'Market is disputed');
            assert(get_block_timestamp() >= proposal_ts + 86400, 'Too early');

            let saved_val = self.market_proposal.entry(market_id).read();
            let final_outcome = saved_val == 2; // 2 is YES

            self._resolve_and_distribute(market_id, final_outcome);
        }

        // 🟢 4. ADJUDICATE (Admin resolves dispute)
        fn adjudicate_dispute(ref self: ContractState, market_id: u64, outcome: bool) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), 'Only admin can judge');
            assert(self.is_disputed.entry(market_id).read(), 'Not disputed');

            let bond = self.dispute_bond.entry(market_id).read();
            let challenger_addr = self.challenger.entry(market_id).read();
            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };

            let proposal_val = self.market_proposal.entry(market_id).read();
            let admin_val = if outcome {
                2
            } else {
                1
            };

            // If Admin agrees with original proposal => Challenger was WRONG (Troll)
            if admin_val == proposal_val {
                // Admin keeps bond (or burn, or send to treasury)
                usdc.transfer(self.admin.read(), bond);
            } else {
                // Challenger was RIGHT => Refund bond
                usdc.transfer(challenger_addr, bond);
            }

            self._resolve_and_distribute(market_id, outcome);
        }

        fn claim_winnings(ref self: ContractState, market_id: u64) {
            let caller = get_caller_address();
            let market = self.markets.entry(market_id).read();
            // Status 3 = Resolved
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
            assert(caller == admin, 'Only Admin can upgrade');
            assert(impl_hash.is_non_zero(), 'Class hash zero');
            replace_class_syscall(impl_hash).unwrap();
            self.version.write(self.version.read() + 1);
            self.emit(Upgraded { implementation: impl_hash });
        }

        fn get_version(self: @ContractState) -> u64 {
            self.version.read()
        }
    }

    // 🟢 INTERNAL HELPER FUNCTION
    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _resolve_and_distribute(ref self: ContractState, market_id: u64, outcome: bool) {
            let mut market = self.markets.entry(market_id).read();
            // Ensure we aren't resolving twice
            assert(market.status != 3, 'Internal: Already resolved');

            // Set Status to 3 (Resolved)
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
    }
}
