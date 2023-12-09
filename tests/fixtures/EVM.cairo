// SPDX-License-Identifier: MIT
// Bare minimum contract for executing bytecode on the EVM interpreter

%lang starknet

// Starkware dependencies
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_block_number, get_block_timestamp

// Local dependencies
from kakarot.interpreter import Interpreter
from kakarot.model import model
from kakarot.stack import Stack
from kakarot.constants import Constants
from kakarot.storages import (
    native_token_address,
    contract_account_class_hash,
    blockhash_registry_address,
    account_proxy_class_hash,
)
from data_availability.starknet import Internals as Starknet
from utils.dict import dict_keys, dict_values

// Constructor
@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    native_token_address_: felt,
    contract_account_class_hash_: felt,
    account_proxy_class_hash_: felt,
    blockhash_registry_address_: felt,
) {
    native_token_address.write(native_token_address_);
    contract_account_class_hash.write(contract_account_class_hash_);
    account_proxy_class_hash.write(account_proxy_class_hash_);
    blockhash_registry_address.write(blockhash_registry_address_);
    return ();
}

func execute{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    origin: model.Address,
    value: felt,
    bytecode_len: felt,
    bytecode: felt*,
    calldata_len: felt,
    calldata: felt*,
) -> (model.EVM*, model.Stack*, model.Memory*) {
    alloc_locals;
    let fp_and_pc = get_fp_and_pc();
    local __fp__: felt* = fp_and_pc.fp_val;

    tempvar address = new model.Address(1, 1);
    let (evm, stack, memory) = Interpreter.execute(
        address=address,
        is_deploy_tx=0,
        origin=&origin,
        bytecode_len=bytecode_len,
        bytecode=bytecode,
        calldata_len=calldata_len,
        calldata=calldata,
        value=value,
        gas_limit=Constants.TRANSACTION_GAS_LIMIT,
        gas_price=0,
    );
    return (evm, stack, memory);
}

@view
func evm_call{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    origin: model.Address,
    value: felt,
    bytecode_len: felt,
    bytecode: felt*,
    calldata_len: felt,
    calldata: felt*,
) -> (
    block_number: felt,
    block_timestamp: felt,
    stack_size: felt,
    stack_keys_len: felt,
    stack_keys: felt*,
    stack_values_len: felt,
    stack_values: Uint256*,
    memory_accesses_len: felt,
    memory_accesses: felt*,
    memory_words_len: felt,
    account_addresses_len: felt,
    account_addresses: felt*,
    starknet_contract_address: felt,
    evm_contract_address: felt,
    return_data_len: felt,
    return_data: felt*,
    gas_left: felt,
    success: felt,
    program_counter: felt,
) {
    alloc_locals;
    let (local block_number) = get_block_number();
    let (local block_timestamp) = get_block_timestamp();
    let (evm, stack, memory) = execute(
        origin, value, bytecode_len, bytecode, calldata_len, calldata
    );

    let (stack_keys_len, stack_keys) = dict_keys(stack.dict_ptr_start, stack.dict_ptr);
    let (stack_values_len, stack_values) = dict_values(stack.dict_ptr_start, stack.dict_ptr);

    let memory_accesses_len = memory.word_dict - memory.word_dict_start;

    // Return only accounts keys, ie. touched starknet addresses
    let (account_addresses_len, account_addresses) = dict_keys(
        evm.state.accounts_start, evm.state.accounts
    );

    return (
        block_number=block_number,
        block_timestamp=block_timestamp,
        stack_size=stack.size,
        stack_keys_len=stack_keys_len,
        stack_keys=stack_keys,
        stack_values_len=stack_values_len,
        stack_values=stack_values,
        memory_accesses_len=memory_accesses_len,
        memory_accesses=memory.word_dict_start,
        memory_words_len=memory.words_len,
        account_addresses_len=account_addresses_len,
        account_addresses=account_addresses,
        starknet_contract_address=evm.message.address.starknet,
        evm_contract_address=evm.message.address.evm,
        return_data_len=evm.return_data_len,
        return_data=evm.return_data,
        gas_left=evm.gas_left,
        success=1 - evm.reverted,
        program_counter=evm.program_counter,
    );
}

@external
func evm_execute{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    origin: model.Address,
    value: felt,
    bytecode_len: felt,
    bytecode: felt*,
    calldata_len: felt,
    calldata: felt*,
) -> (return_data_len: felt, return_data: felt*, success: felt) {
    alloc_locals;
    let (evm, stack, memory) = execute(
        origin, value, bytecode_len, bytecode, calldata_len, calldata
    );
    let result = (evm.return_data_len, evm.return_data, 1 - evm.reverted);

    if (evm.reverted != FALSE) {
        return result;
    }

    // We just emit the events as committing the accounts is out of the scope of these EVM
    // tests and requires a real Message.address (not Address(1, 1))
    Starknet._emit_events(evm.state.events_len, evm.state.events);
    return result;
}
