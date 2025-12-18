use starknet::ContractAddress;
use starknet::class_hash::ClassHash;


#[starknet::interface]
pub trait IStarkZuriGamification<TContractState> {
    fn register_action(ref self: TContractState, user: ContractAddress, action_type: felt252);
    fn claim_daily_reward(ref self: TContractState);
    fn get_user_stats(self: @TContractState, user: ContractAddress) -> UserStats;
    fn get_level(self: @TContractState, user: ContractAddress) -> u64;
    fn set_controller(ref self: TContractState, controller: ContractAddress, allowed: bool);
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
}

// FIX 1: Added 'Copy' and 'Clone' so we can use stats multiple times
#[derive(Drop, Serde, starknet::Store, Copy, Clone)]
pub struct UserStats {
    pub total_xp: u64,
    pub current_streak: u64,
    pub last_active_time: u64,
    pub achievements_mask: u256,
    pub trades_count: u64,
}

#[starknet::contract]
mod StarkZuriGamification {
    use core::num::traits::Zero;
    use starknet::class_hash::ClassHash;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::UserStats;


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        XPAwarded: XPAwarded,
        LevelUp: LevelUp,
        StreakUpdated: StreakUpdated,
        AchievementUnlocked: AchievementUnlocked,
    }

    #[derive(Drop, starknet::Event)]
    struct XPAwarded {
        #[key]
        user: ContractAddress,
        amount: u64,
        reason: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct LevelUp {
        #[key]
        user: ContractAddress,
        new_level: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct StreakUpdated {
        #[key]
        user: ContractAddress,
        new_streak: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct AchievementUnlocked {
        #[key]
        user: ContractAddress,
        achievement_id: felt252,
    }

    #[storage]
    struct Storage {
        user_stats: Map<ContractAddress, UserStats>,
        authorized_controllers: Map<ContractAddress, bool>,
        owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
        self.authorized_controllers.entry(owner).write(true);
    }

    #[abi(embed_v0)]
    impl GamificationImpl of super::IStarkZuriGamification<ContractState> {
        fn set_controller(ref self: ContractState, controller: ContractAddress, allowed: bool) {
            assert(get_caller_address() == self.owner.read(), 'Not Owner');
            self.authorized_controllers.entry(controller).write(allowed);
        }

        fn register_action(ref self: ContractState, user: ContractAddress, action_type: felt252) {
            let caller = get_caller_address();
            assert(self.authorized_controllers.entry(caller).read(), 'Unauthorized Controller');

            let mut stats = self.user_stats.entry(user).read();
            let mut xp_gain = 0;

            if action_type == 'TRADE' {
                stats.trades_count += 1;
                xp_gain = 50;

                if stats.trades_count == 10 {
                    xp_gain += 150;
                    self.emit(AchievementUnlocked { user, achievement_id: 'MARKET_CREATOR' });
                }
            } else if action_type == 'CREATE_MARKET' {
                xp_gain = 100;
            } else if action_type == 'REFERRAL' {
                xp_gain = 200;
            }

            self._add_xp(user, ref stats, xp_gain, action_type);
            self.user_stats.entry(user).write(stats);
        }

        fn claim_daily_reward(ref self: ContractState) {
            let user = get_caller_address();
            let mut stats = self.user_stats.entry(user).read();
            let now = get_block_timestamp();

            let one_day = 86400;
            let time_diff = now - stats.last_active_time;

            if stats.last_active_time == 0 {
                stats.current_streak = 1;
            } else if time_diff < one_day {
                return;
            } else if time_diff < (one_day * 2) {
                stats.current_streak += 1;
            } else {
                stats.current_streak = 1;
            }

            stats.last_active_time = now;

            let bonus = if stats.current_streak > 7 {
                15
            } else {
                0
            };
            let reward = 35 + bonus;

            self._add_xp(user, ref stats, reward, 'DAILY_STREAK');

            // FIX 2: We can now use 'stats' after write because of Copy/Clone
            self.user_stats.entry(user).write(stats);
            self.emit(StreakUpdated { user, new_streak: stats.current_streak });
        }

        fn get_user_stats(self: @ContractState, user: ContractAddress) -> UserStats {
            self.user_stats.entry(user).read()
        }

        fn get_level(self: @ContractState, user: ContractAddress) -> u64 {
            let stats = self.user_stats.entry(user).read();
            let xp = stats.total_xp;

            if xp < 100 {
                return 1;
            }

            let mut i = 1;
            loop {
                if i * i * 100 > xp {
                    break i - 1;
                }
                i += 1;
            }
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            assert(get_caller_address() == self.owner.read(), 'Not Owner');
            assert(impl_hash.is_non_zero(), 'Class hash zero');
            replace_class_syscall(impl_hash).unwrap();
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _add_xp(
            ref self: ContractState,
            user: ContractAddress,
            ref stats: UserStats,
            amount: u64,
            reason: felt252,
        ) {
            let old_level = self.get_level(user);

            stats.total_xp += amount;

            // FIX 3: We can use 'stats' safely here due to Copy
            self.user_stats.entry(user).write(stats);
            let new_level = self.get_level(user);

            self.emit(XPAwarded { user, amount, reason });

            if new_level > old_level {
                self.emit(LevelUp { user, new_level });
            }
        }
    }
}
