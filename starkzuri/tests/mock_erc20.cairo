#[starknet::contract]
mod MockERC20 {
    // FIX: Import the modern storage traits
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        // FIX: Use Map instead of LegacyMap
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        recipient: ContractAddress,
    ) {
        // FIX: Use .entry() syntax
        self.balances.entry(recipient).write(initial_supply);
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
        let sender = get_caller_address();
        let current_bal = self.balances.entry(sender).read();

        self.balances.entry(sender).write(current_bal - amount);

        let recipient_bal = self.balances.entry(recipient).read();
        self.balances.entry(recipient).write(recipient_bal + amount);
        true
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
        let owner = get_caller_address();
        self.allowances.entry((owner, spender)).write(amount);
        true
    }

    #[external(v0)]
    fn transferFrom(
        ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool {
        let caller = get_caller_address();

        // 1. Update Allowance
        let current_allowance = self.allowances.entry((sender, caller)).read();
        self.allowances.entry((sender, caller)).write(current_allowance - amount);

        // 2. Transfer
        let sender_bal = self.balances.entry(sender).read();
        self.balances.entry(sender).write(sender_bal - amount);

        let recipient_bal = self.balances.entry(recipient).read();
        self.balances.entry(recipient).write(recipient_bal + amount);
        true
    }

    #[external(v0)]
    fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
        self.balances.entry(account).read()
    }
}
