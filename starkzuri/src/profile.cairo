use starknet::ContractAddress;
use starknet::class_hash::ClassHash;


#[starknet::interface]
pub trait IStarkZuriProfile<TContractState> {
    fn set_profile(
        ref self: TContractState,
        username: felt252,
        display_name: ByteArray,
        bio: ByteArray,
        avatar_uri: ByteArray,
        referrer: ContractAddress,
    );

    fn get_profile(self: @TContractState, user: ContractAddress) -> Profile;
    fn get_address_from_username(self: @TContractState, username: felt252) -> ContractAddress;
    fn get_referral_count(self: @TContractState, user: ContractAddress) -> u64;
    fn upgrade(ref self: TContractState, impl_hash: ClassHash);
}

// FIX 1: Added 'Clone' to the derive list
#[derive(Drop, Serde, starknet::Store, Clone)]
pub struct Profile {
    pub username: felt252,
    pub display_name: ByteArray,
    pub bio: ByteArray,
    pub avatar_uri: ByteArray,
    pub referrer: ContractAddress,
    pub referral_count: u64,
    pub is_registered: bool,
}

#[starknet::contract]
mod StarkZuriProfile {
    use core::num::traits::Zero;
    use starknet::class_hash::ClassHash;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ContractAddress, get_caller_address};
    use super::Profile;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ProfileUpdated: ProfileUpdated,
        ReferralRegistered: ReferralRegistered,
    }

    #[derive(Drop, starknet::Event)]
    struct ProfileUpdated {
        #[key]
        user: ContractAddress,
        #[key]
        username: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ReferralRegistered {
        #[key]
        referrer: ContractAddress,
        #[key]
        new_user: ContractAddress,
        timestamp: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin_address: ContractAddress) {
        self.admin.write(admin_address);
    }

    #[storage]
    struct Storage {
        profiles: Map<ContractAddress, Profile>,
        username_registry: Map<felt252, ContractAddress>,
        admin: ContractAddress,
    }

    #[abi(embed_v0)]
    impl StarkZuriProfileImpl of super::IStarkZuriProfile<ContractState> {
        fn set_profile(
            ref self: ContractState,
            username: felt252,
            display_name: ByteArray,
            bio: ByteArray,
            avatar_uri: ByteArray,
            referrer: ContractAddress,
        ) {
            let caller = get_caller_address();

            // 1. Check Username Uniqueness
            let existing_address = self.username_registry.entry(username).read();

            if existing_address.is_non_zero() {
                assert(existing_address == caller, 'Username already taken');
            }

            // 2. Load Existing Profile
            let mut current_profile = self.profiles.entry(caller).read();
            let mut final_referrer = current_profile.referrer;

            if !current_profile.is_registered {
                if referrer.is_non_zero() && referrer != caller {
                    final_referrer = referrer;

                    // Update Referrer Stats
                    let mut referrer_profile = self.profiles.entry(referrer).read();
                    if referrer_profile.is_registered {
                        referrer_profile.referral_count += 1;

                        // FIX 2: Use .clone() here to keep the compiler happy
                        self.profiles.entry(referrer).write(referrer_profile.clone());

                        self
                            .emit(
                                ReferralRegistered {
                                    referrer: referrer,
                                    new_user: caller,
                                    timestamp: starknet::get_block_timestamp(),
                                },
                            );
                    }
                }
            }

            // 3. Save Profile
            let new_profile = Profile {
                username: username,
                display_name: display_name,
                bio: bio,
                avatar_uri: avatar_uri,
                referrer: final_referrer,
                referral_count: current_profile.referral_count,
                is_registered: true,
            };

            self.profiles.entry(caller).write(new_profile);
            self.username_registry.entry(username).write(caller);

            self
                .emit(
                    ProfileUpdated {
                        user: caller,
                        username: username,
                        timestamp: starknet::get_block_timestamp(),
                    },
                );
        }

        fn get_profile(self: @ContractState, user: ContractAddress) -> Profile {
            self.profiles.entry(user).read()
        }

        fn get_address_from_username(self: @ContractState, username: felt252) -> ContractAddress {
            self.username_registry.entry(username).read()
        }

        fn get_referral_count(self: @ContractState, user: ContractAddress) -> u64 {
            let profile = self.profiles.entry(user).read();
            profile.referral_count
        }

        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            assert(get_caller_address() == self.admin.read(), 'Not Admin');
            assert(impl_hash.is_non_zero(), 'Class hash zero');
            replace_class_syscall(impl_hash).unwrap();
        }
    }
}
