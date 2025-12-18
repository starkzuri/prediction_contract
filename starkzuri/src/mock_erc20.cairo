use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockERC20<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
}

#[starknet::contract]
mod MockERC20 {
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        name: ByteArray,
        symbol: ByteArray,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        total_supply: u256,
    }

    // FIX: This constructor now accepts ByteArray to match the test!
    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        initial_supply: u256,
        recipient: ContractAddress,
    ) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.mint(recipient, initial_supply);
    }

    #[abi(embed_v0)]
    impl MockERC20Impl of super::IMockERC20<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            let current = self.balances.entry(recipient).read();
            self.balances.entry(recipient).write(current + amount);
            self.total_supply.write(self.total_supply.read() + amount);
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            let sender_balance = self.balances.entry(sender).read();
            assert(sender_balance >= amount, 'Insufficient balance');

            self.balances.entry(sender).write(sender_balance - amount);
            self.balances.entry(recipient).write(self.balances.entry(recipient).read() + amount);
            true
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let allowance = self.allowances.entry((sender, caller)).read();
            assert(allowance >= amount, 'Insufficient allowance');

            self.allowances.entry((sender, caller)).write(allowance - amount);

            let sender_balance = self.balances.entry(sender).read();
            assert(sender_balance >= amount, 'Insufficient balance');

            self.balances.entry(sender).write(sender_balance - amount);
            self.balances.entry(recipient).write(self.balances.entry(recipient).read() + amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.allowances.entry((caller, spender)).write(amount);
            true
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.entry(account).read()
        }
    }
}
