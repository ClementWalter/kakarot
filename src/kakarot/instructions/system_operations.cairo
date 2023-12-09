// SPDX-License-Identifier: MIT

%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_bigend, finalize_keccak
from starkware.cairo.common.math import split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le, is_nn, is_not_zero
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.uint256 import Uint256, uint256_lt

from kakarot.account import Account
from kakarot.constants import Constants
from kakarot.errors import Errors
from kakarot.evm import EVM
from kakarot.gas import Gas
from kakarot.memory import Memory
from kakarot.model import model
from kakarot.precompiles.precompiles import Precompiles
from kakarot.stack import Stack
from kakarot.state import State
from utils.array import slice
from utils.bytes import (
    bytes_to_bytes8_little_endian,
    felt_to_bytes,
    felt_to_bytes20,
    uint256_to_bytes32,
)
from utils.uint256 import uint256_to_uint160

// @title System operations opcodes.
// @notice This file contains the functions to execute for system operations opcodes.
namespace SystemOperations {
    func exec_create{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let state = evm.state;

        let opcode_number = [evm.message.bytecode + evm.program_counter];
        let is_create2 = is_not_zero(opcode_number - 0xf0);
        let popped_len = 3 + is_create2;
        let (popped) = Stack.pop_n(3 + is_create2);

        let value = popped[0];
        let offset = popped[1];
        let size = popped[2];

        // Gas
        // + extend_memory.cost
        // + init_code_gas
        // + is_create2 * GAS_KECCAK256_WORD * call_data_words
        let memory_expansion_cost = Gas.memory_expansion_cost(
            memory.words_len, offset.low + size.low
        );
        // If .high != 0, OOG is surely triggered. So we only use the .low part for the
        // actual computation, and add evm.gas_left * .high which would
        // either be 0 or evm.gas_left * k, thus triggering OOG.
        let memory_expansion_cost = evm.gas_left * (offset.high + size.high) +
            memory_expansion_cost;
        let (calldata_words, _) = unsigned_div_rem(size.low + 31, 31);
        let init_code_gas = Gas.INIT_CODE_WORD_COST * calldata_words;
        let calldata_word_gas = is_create2 * Gas.KECCAK256_WORD * calldata_words;
        let evm = EVM.charge_gas(evm, memory_expansion_cost + init_code_gas + calldata_word_gas);
        if (evm.reverted != FALSE) {
            return evm;
        }

        // Load bytecode
        let (bytecode: felt*) = alloc();
        Memory.load_n(size.low, bytecode, offset.low);

        // Get target address
        let (state, evm_contract_address) = CreateHelper.get_evm_address(
            state, evm.message.address, popped_len, popped, size.low, bytecode
        );
        let (starknet_contract_address) = Account.compute_starknet_address(evm_contract_address);
        tempvar address = new model.Address(starknet_contract_address, evm_contract_address);

        // Get message call gas
        let (gas_limit, _) = unsigned_div_rem(evm.gas_left, 64);
        let gas_limit = evm.gas_left - gas_limit;

        if (evm.message.read_only != FALSE) {
            let evm = EVM.charge_gas(evm, gas_limit);
            let (revert_reason_len, revert_reason) = Errors.stateModificationError();
            let evm = EVM.stop(evm, revert_reason_len, revert_reason, TRUE);
            let evm = EVM.update_state(evm, state);
            return evm;
        }

        // TODO: Clear return data

        // Check sender balance and nonce
        let (state, sender) = State.get_account(state, evm.message.address);
        let is_nonce_overflow = is_le(Constants.MAX_NONCE + 1, sender.nonce);
        let (is_balance_overflow) = uint256_lt([sender.balance], value);
        // TODO: missing stack depth limit
        if (is_nonce_overflow + is_balance_overflow != 0) {
            Stack.push_uint128(0);
            let evm = EVM.update_state(evm, state);
            return evm;
        }

        let evm = EVM.charge_gas(evm, gas_limit);

        // Check target account availabitliy
        let (state, account) = State.get_account(state, address);
        let is_collision = Account.has_code_or_nonce(account);
        if (is_collision != 0) {
            let sender = Account.set_nonce(sender, sender.nonce + 1);
            let state = State.set_account(state, evm.message.address, sender);
            Stack.push_uint128(0);
            let evm = EVM.update_state(evm, state);
            return evm;
        }

        // Check code size
        let code_size_too_big = is_le(2 * Constants.MAX_CODE_SIZE + 1, size.low);
        if (code_size_too_big != FALSE) {
            let evm = EVM.charge_gas(evm, evm.gas_left + 1);
            let evm = EVM.update_state(evm, state);
            return evm;
        }

        // Increment nonce
        let sender = Account.set_nonce(sender, sender.nonce + 1);
        let state = State.set_account(state, evm.message.address, sender);

        // Final update of calling context
        let evm = EVM.update_state(evm, state);
        tempvar parent = new model.Parent(evm, stack, memory);
        let stack = Stack.init();
        let memory = Memory.init();
        let state = State.copy(evm.state);

        // Create child message
        let (calldata: felt*) = alloc();
        tempvar message = new model.Message(
            bytecode=bytecode,
            bytecode_len=size.low,
            calldata=calldata,
            calldata_len=0,
            value=value.low + value.high * 2 ** 128,
            gas_price=evm.message.gas_price,
            origin=evm.message.origin,
            parent=parent,
            address=address,
            read_only=FALSE,
            is_create=TRUE,
            depth=evm.message.depth + 1,
        );
        let child_evm = EVM.init(message, gas_limit);
        let stack = Stack.init();

        let (state, account) = State.get_account(state, address);
        let account = Account.set_nonce(account, 1);
        let state = State.set_account(state, address, account);

        let transfer = model.Transfer(evm.message.address, address, value);
        let (state, success) = State.add_transfer(state, transfer);
        let child_evm = EVM.update_state(child_evm, state);
        if (success == 0) {
            Stack.push_uint128(0);
            let child_evm = EVM.update_state(child_evm, state);
            return child_evm;
        }

        return child_evm;
    }

    // @notice INVALID operation.
    // @dev Equivalent to REVERT (since Byzantium fork) with 0,0 as stack parameters,
    //      except that all the gas given to the current context is consumed.
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas NaN
    // @custom:stack_consumed_elements 0
    // @custom:stack_produced_elements 0
    // @param evm The pointer to the execution context
    // @return EVM The pointer to the updated execution context.
    func exec_invalid{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        let evm = EVM.charge_gas(evm, evm.gas_left);
        let (revert_reason: felt*) = alloc();
        let evm = EVM.stop(evm, 0, revert_reason, TRUE);
        return evm;
    }

    // @notice RETURN operation.
    // @dev Halt execution returning output data
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas NaN
    // @custom:stack_consumed_elements 2
    // @custom:stack_produced_elements 0
    // @return EVM The pointer to the updated execution context.
    func exec_return{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (popped) = Stack.pop_n(2);
        let offset = popped[0];
        let size = popped[1];

        let memory_expansion_cost = Gas.memory_expansion_cost(
            memory.words_len, offset.low + size.low
        );
        let evm = EVM.charge_gas(evm, memory_expansion_cost);
        if (evm.reverted != FALSE) {
            return evm;
        }

        let (local return_data: felt*) = alloc();
        Memory.load_n(size.low, return_data, offset.low);

        let evm = EVM.stop(evm, size.low, return_data, FALSE);

        return evm;
    }

    // @notice REVERT operation.
    // @dev
    // @custom:since Byzantium
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 2
    // @custom:stack_produced_elements 0
    // @return EVM The pointer to the updated execution context.
    func exec_revert{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (popped) = Stack.pop_n(2);
        let offset = popped[0];
        let size = popped[1];

        let memory_expansion_cost = Gas.memory_expansion_cost(
            memory.words_len, offset.low + size.low
        );
        let evm = EVM.charge_gas(evm, memory_expansion_cost);
        if (evm.reverted != FALSE) {
            return evm;
        }

        // Load revert reason from offset
        let (return_data: felt*) = alloc();
        Memory.load_n(size.low, return_data, offset.low);

        let evm = EVM.stop(evm, size.low, return_data, TRUE);
        return evm;
    }

    // @notice CALL operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 7
    // @custom:stack_produced_elements 1
    // @return EVM The pointer to the sub context.
    func exec_call{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;
        let child_evm = CallHelper.init_sub_context(
            evm=evm, with_value=TRUE, read_only=evm.message.read_only, self_call=FALSE
        );
        if (child_evm.reverted != 0) {
            return child_evm;
        }

        if (evm.message.read_only * child_evm.message.value != FALSE) {
            let (revert_reason_len, revert_reason) = Errors.stateModificationError();
            let evm = child_evm.message.parent.evm;
            let evm = EVM.stop(evm, revert_reason_len, revert_reason, TRUE);
            return evm;
        }

        let (value_high, value_low) = split_felt(child_evm.message.value);
        tempvar value = Uint256(value_low, value_high);

        let transfer = model.Transfer(evm.message.address, child_evm.message.address, value);
        let (state, success) = State.add_transfer(child_evm.state, transfer);
        let child_evm = EVM.update_state(child_evm, state);
        if (success == 0) {
            let (revert_reason_len, revert_reason) = Errors.balanceError();
            tempvar child_evm = EVM.stop(child_evm, revert_reason_len, revert_reason, TRUE);
        } else {
            tempvar child_evm = child_evm;
        }

        return child_evm;
    }

    // @notice STATICCALL operation.
    // @dev
    // @custom:since Homestead
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 6
    // @custom:stack_produced_elements 1
    // @return EVM The pointer to the sub context.
    func exec_staticcall{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        let child_evm = CallHelper.init_sub_context(
            evm=evm, with_value=FALSE, read_only=TRUE, self_call=FALSE
        );
        return child_evm;
    }

    // @notice CALLCODE operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 7
    // @custom:stack_produced_elements 1
    // @return EVM The pointer to the sub context.
    func exec_callcode{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        let child_evm = CallHelper.init_sub_context(
            evm=evm, with_value=TRUE, read_only=evm.message.read_only, self_call=TRUE
        );

        return child_evm;
    }

    // @notice DELEGATECALL operation.
    // @dev
    // @custom:since Byzantium
    // @custom:group System Operations
    // @custom:gas 0 + dynamic gas
    // @custom:stack_consumed_elements 6
    // @custom:stack_produced_elements 1
    // @return EVM The pointer to the sub context.
    func exec_delegatecall{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        let child_evm = CallHelper.init_sub_context(
            evm=evm, with_value=FALSE, read_only=evm.message.read_only, self_call=TRUE
        );

        return child_evm;
    }

    // @notice SELFDESTRUCT operation.
    // @dev
    // @custom:since Frontier
    // @custom:group System Operations
    // @custom:gas 3000 + dynamic gas
    // @custom:stack_consumed_elements 1
    // @return EVM The pointer to the updated execution_context.
    func exec_selfdestruct{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        if (evm.message.read_only != FALSE) {
            let (revert_reason_len, revert_reason) = Errors.stateModificationError();
            let evm = EVM.stop(evm, revert_reason_len, revert_reason, TRUE);
            return evm;
        }

        // Transfer funds
        let (popped) = Stack.pop();
        let recipient_evm_address = uint256_to_uint160([popped]);

        // Remove this when https://eips.ethereum.org/EIPS/eip-6780 is validated
        if (recipient_evm_address == evm.message.address.evm) {
            tempvar is_recipient_self = TRUE;
        } else {
            tempvar is_recipient_self = FALSE;
        }
        let recipient_evm_address = (1 - is_recipient_self) * recipient_evm_address;

        let (recipient_starknet_address) = Account.compute_starknet_address(recipient_evm_address);
        tempvar recipient = new model.Address(recipient_starknet_address, recipient_evm_address);
        let (state, account) = State.get_account(evm.state, evm.message.address);
        let transfer = model.Transfer(
            sender=evm.message.address, recipient=recipient, amount=[account.balance]
        );
        let (state, success) = State.add_transfer(state, transfer);

        // Register for SELFDESTRUCT
        let (state, account) = State.get_account(state, evm.message.address);
        let account = Account.selfdestruct(account);
        let state = State.set_account(state, evm.message.address, account);

        // Halt context
        let (return_data: felt*) = alloc();
        let evm = EVM.stop(evm, 0, return_data, FALSE);

        let evm = EVM.update_state(evm, state);

        return evm;
    }
}

namespace CallHelper {
    // @notice The shared logic of the CALL ops, allowing CALL, CALLCODE, STATICCALL, and DELEGATECALL to
    //         share structure and parameterize whether the call requires a value (CALL, CALLCODE) and
    //         whether the returned sub context's is read only (STATICCODE)
    // @param calling_evm The pointer to the calling execution context.
    // @param with_value The boolean that determines whether the sub-context's calling context has a value read
    //        from the calling context's stack or the calling context's calling context.
    // @param read_only The boolean that determines whether state modifications can be executed from the sub-execution context.
    // @param self_call A boolean to indicate whether the account to message-call into is self (address of the current executing account)
    //        or the call argument's address (address of the call's target account)
    // @return EVM The pointer to the sub context.
    func init_sub_context{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*, with_value: felt, read_only: felt, self_call: felt) -> model.EVM* {
        alloc_locals;

        // 1. Parse args from Stack
        // Note: We don't pop ret_offset and ret_size here but at the end of the sub context
        // See finalize_parent
        // Pop ret_offset and ret_size
        let (popped) = Stack.pop_n(4 + with_value);
        let (ret_offset_uint256) = Stack.peek(0);
        let (ret_size_uint256) = Stack.peek(1);

        let gas = popped[0];
        let address = uint256_to_uint160(popped[1]);
        let stack_value = (2 ** 128 * popped[2].high + popped[2].low) * with_value;
        // If the call op expects value to be on the stack, we return it
        // Otherwise, the value is the calling call context value
        let value = with_value * stack_value + (1 - with_value) * evm.message.value;
        let args_offset = 2 ** 128 * popped[2 + with_value].high + popped[2 + with_value].low;
        let args_size = 2 ** 128 * popped[3 + with_value].high + popped[3 + with_value].low;
        let ret_offset = 2 ** 128 * ret_offset_uint256.high + ret_offset_uint256.low;
        let ret_size = 2 ** 128 * ret_size_uint256.high + ret_size_uint256.low;

        // 2. Gas
        // Memory expansion cost
        let max_expansion_is_ret = is_le(args_offset + args_size, ret_offset + ret_size);
        let max_expansion = max_expansion_is_ret * (ret_offset + ret_size) + (
            1 - max_expansion_is_ret
        ) * (args_offset + args_size);
        let memory_expansion_cost = Gas.memory_expansion_cost(memory.words_len, max_expansion);

        // Access list
        // TODO

        // Max between given gas arg and max allowed gas := available_gas - (available_gas // 64)
        let (max_message_call_gas, _) = unsigned_div_rem(evm.gas_left, 64);
        tempvar max_message_call_gas = evm.gas_left - max_message_call_gas;
        let (max_message_call_gas_high, max_message_call_gas_low) = split_felt(
            max_message_call_gas
        );
        let (max_gas_is_message_call_gas) = uint256_lt(
            Uint256(max_message_call_gas_low, max_message_call_gas_high), gas
        );
        local gas_limit;
        if (max_gas_is_message_call_gas == FALSE) {
            // If gas is lower, it means that it fits in a felt and this is safe
            assert gas_limit = gas.low + gas.high * 2 ** 128;
        } else {
            assert gas_limit = max_message_call_gas;
        }
        // All the gas is charged upfront and remaining gis is refunded at the end
        let evm = EVM.charge_gas(evm, gas_limit + memory_expansion_cost);
        if (evm.reverted != FALSE) {
            return evm;
        }

        // 3. Calldata
        let (calldata: felt*) = alloc();
        Memory.load_n(args_size, calldata, args_offset);

        // 4. Build child_evm
        // Check if the called address is a precompiled contract
        let is_precompile = Precompiles.is_precompile(address=address);
        if (is_precompile != FALSE) {
            tempvar parent = new model.Parent(evm, stack, memory);
            let child_evm = Precompiles.run(
                evm_address=address,
                calldata_len=args_size,
                calldata=calldata,
                value=value,
                parent=parent,
                gas_left=gas_limit,
            );

            return child_evm;
        }

        let (starknet_contract_address) = Account.compute_starknet_address(address);
        tempvar call_address = new model.Address(starknet_contract_address, address);
        let (state, account) = State.get_account(evm.state, call_address);
        let evm = EVM.update_state(evm, state);

        if (self_call == FALSE) {
            tempvar message_address = call_address;
        } else {
            tempvar message_address = evm.message.address;
        }

        tempvar parent = new model.Parent(evm, stack, memory);
        let stack = Stack.init();
        let memory = Memory.init();
        tempvar message = new model.Message(
            bytecode=account.code,
            bytecode_len=account.code_len,
            calldata=calldata,
            calldata_len=args_size,
            value=value,
            gas_price=evm.message.gas_price,
            origin=evm.message.origin,
            parent=parent,
            address=message_address,
            read_only=read_only,
            is_create=FALSE,
            depth=evm.message.depth + 1,
        );
        let child_evm = EVM.init(message, gas_limit);
        let state = State.copy(evm.state);
        let child_evm = EVM.update_state(child_evm, state);
        return child_evm;
    }

    // @return EVM The pointer to the updated calling context.
    func finalize_parent{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        // Pop ret_offset and ret_size
        // See init_sub_context, the Stack here is guaranteed to have enough items
        let (popped) = Stack.pop_n(n=2);
        let ret_offset = 2 ** 128 * popped[0].high + popped[0].low;
        let ret_size = 2 ** 128 * popped[1].high + popped[1].low;

        // Put status in stack
        Stack.push_uint128(1 - evm.reverted);

        // Store RETURN_DATA in memory
        let (return_data: felt*) = alloc();
        slice(return_data, evm.return_data_len, evm.return_data, 0, ret_size);
        Memory.store_n(ret_size, return_data, ret_offset);

        // Gas not used is returned when evm is not reverted
        local gas_left;
        if (evm.reverted == FALSE) {
            assert gas_left = evm.message.parent.evm.gas_left + evm.gas_left;
            tempvar state = evm.state;
        } else {
            assert gas_left = evm.message.parent.evm.gas_left;
            tempvar state = evm.message.parent.evm.state;
        }

        tempvar evm = new model.EVM(
            state=state,
            message=evm.message.parent.evm.message,
            return_data_len=evm.return_data_len,
            return_data=evm.return_data,
            program_counter=evm.message.parent.evm.program_counter + 1,
            stopped=evm.message.parent.evm.stopped,
            gas_left=gas_left,
            reverted=evm.message.parent.evm.reverted,
        );

        return evm;
    }
}

namespace CreateHelper {
    // @notice Constructs an evm contract address for the create opcode
    //         via last twenty bytes of the keccak hash of:
    //         keccak256(rlp([sender_address,sender_nonce])).
    //         See [CREATE](https://www.evm.codes/#f0).
    // @param sender_address The evm sender address.
    // @param bytecode_len The length of the initialization code.
    // @param nonce The nonce given to the create opcode.
    // @return EVM The pointer to the updated calling context.
    func get_create_address{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(sender_address: felt, nonce: felt) -> (evm_contract_address: felt) {
        alloc_locals;
        local message_len;
        // rlp([address, nonce]) inlined to save unnecessary expensive general RLP encoding
        // final bytes is either
        // (0xc0 + bytes_lenght) + (0x80 + 20) + address + nonce
        // or
        // (0xc0 + bytes_lenght) + (0x80 + 20) + address + (0x80 + nonce_len) + nonce
        let (message: felt*) = alloc();
        assert [message + 1] = 0x80 + 20;
        felt_to_bytes20(message + 2, sender_address);
        let encode_nonce = is_le(0x80, nonce);
        if (encode_nonce != FALSE) {
            let nonce_len = felt_to_bytes(message + 2 + 20 + 1, nonce);
            assert [message + 2 + 20] = 0x80 + nonce_len;
            assert message_len = 1 + 1 + 20 + 1 + nonce_len;
        } else {
            let is_nonce_not_zero = is_not_zero(nonce);
            let encoded_nonce = nonce * is_nonce_not_zero + (1 - is_nonce_not_zero) * 0x80;
            assert [message + 2 + 20] = encoded_nonce;
            assert message_len = 1 + 1 + 20 + 1;
        }
        assert message[0] = message_len + 0xc0 - 1;

        let (message_bytes8: felt*) = alloc();
        bytes_to_bytes8_little_endian(message_bytes8, message_len, message);

        let (keccak_ptr: felt*) = alloc();
        local keccak_ptr_start: felt* = keccak_ptr;
        with keccak_ptr {
            let (message_hash) = cairo_keccak_bigend(message_bytes8, message_len);
        }

        finalize_keccak(keccak_ptr_start, keccak_ptr);

        let address = uint256_to_uint160(message_hash);
        return (address,);
    }

    // @notice Constructs an evm contract address for the create2 opcode
    //         via last twenty bytes of the keccak hash of:
    //         keccak256(0xff + sender_address + salt +
    //         keccak256(initialization_code))[12:].
    //         See [CREATE2](https://www.evm.codes/#f5).
    // @param sender_address The evm sender address.
    // @param bytecode_len The length of the initialization code.
    // @param bytecode The offset to store the element at.
    // @param salt The salt given to the create2 opcode.
    // @return EVM The pointer to the updated calling context.
    func get_create2_address{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(sender_address: felt, bytecode_len: felt, bytecode: felt*, salt: Uint256) -> (
        evm_contract_address: felt
    ) {
        alloc_locals;
        let (keccak_ptr: felt*) = alloc();
        local keccak_ptr_start: felt* = keccak_ptr;

        let (local bytecode_bytes8: felt*) = alloc();
        bytes_to_bytes8_little_endian(bytecode_bytes8, bytecode_len, bytecode);
        with keccak_ptr {
            let (bytecode_hash) = cairo_keccak_bigend(bytecode_bytes8, bytecode_len);
        }

        // get keccak hash of
        // marker + caller_address + salt + bytecode_hash
        let (local packed_bytes: felt*) = alloc();

        // 0xff is by convention the marker involved in deterministic address creation for create2
        assert [packed_bytes] = 0xff;
        felt_to_bytes20(packed_bytes + 1, sender_address);
        uint256_to_bytes32(packed_bytes + 1 + 20, salt);
        uint256_to_bytes32(packed_bytes + 1 + 20 + 32, bytecode_hash);
        let packed_bytes_len = 1 + 20 + 32 + 32;

        let (local packed_bytes8: felt*) = alloc();
        bytes_to_bytes8_little_endian(packed_bytes8, packed_bytes_len, packed_bytes);

        with keccak_ptr {
            let (create2_hash) = cairo_keccak_bigend(packed_bytes8, packed_bytes_len);
        }

        finalize_keccak(keccak_ptr_start, keccak_ptr);

        let create2_address = uint256_to_uint160(create2_hash);
        return (create2_address,);
    }

    // @notice Pre-compute the evm address of a contract account before deploying it.
    func get_evm_address{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(
        state: model.State*,
        address: model.Address*,
        popped_len: felt,
        popped: Uint256*,
        bytecode_len: felt,
        bytecode: felt*,
    ) -> (model.State*, felt) {
        alloc_locals;
        let (state, account) = State.get_account(state, address);
        let nonce = account.nonce;

        // create2 context pops 4 off the stack, create pops 3
        // so we use popped_len to derive the way we should handle
        // the creation of evm addresses
        if (popped_len != 4) {
            let (evm_contract_address) = CreateHelper.get_create_address(address.evm, nonce);
            return (state, evm_contract_address);
        } else {
            let salt = popped[3];
            let (evm_contract_address) = CreateHelper.get_create2_address(
                sender_address=address.evm, bytecode_len=bytecode_len, bytecode=bytecode, salt=salt
            );
            return (state, evm_contract_address);
        }
    }

    // @notice At the end of a sub-context initiated with CREATE or CREATE2, the calling context's stack is updated.
    // @param evm The pointer to the calling context.
    // @return EVM The pointer to the updated calling context.
    func finalize_parent{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        // Charge final deposit gas
        let code_size_limit = is_le(evm.return_data_len, Constants.MAX_CODE_SIZE);
        let code_deposit_cost = Gas.CODE_DEPOSIT * evm.return_data_len;
        let remaining_gas = evm.gas_left - code_deposit_cost;
        let enough_gas = is_nn(remaining_gas);
        let success = (1 - evm.reverted) * enough_gas * code_size_limit;

        // Stack output: the address of the deployed contract, 0 if the deployment failed.
        let (address_high, address_low) = split_felt(evm.message.address.evm * success);
        tempvar address = new Uint256(low=address_low, high=address_high);

        Stack.push(address);

        // Re-create the calling context with updated stack and return_data
        // Gas not used is returned when evm is not reverted
        // In the case of a reverted create context, the gas of the reverted context should be rolled back and not consumed
        tempvar evm = new model.EVM(
            state=evm.message.parent.evm.state,
            message=evm.message.parent.evm.message,
            return_data_len=evm.return_data_len,
            return_data=evm.return_data,
            program_counter=evm.message.parent.evm.program_counter + 1,
            stopped=evm.message.parent.evm.stopped,
            gas_left=evm.message.parent.evm.gas_left + remaining_gas * success,
            reverted=evm.message.parent.evm.reverted,
        );

        // REVERTED, just returns
        if (success == FALSE) {
            return evm;
        }

        // Write bytecode to Account
        let (state, account) = State.get_account(evm.state, evm.message.address);
        let account = Account.set_code(account, evm.return_data_len, evm.return_data);
        let state = State.set_account(state, evm.message.address, account);

        let evm = EVM.update_state(evm, state);

        return evm;
    }
}
