// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

/// @notice A library to interact with the 0x75001 Whitelisted Cairo Call precompile.
library WhitelistedCallCairoLib {
    /// @dev The Cairo precompile contract's address.
    address constant WHITELISTED_CALL_CAIRO_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000075001;

    /// @notice Calls the Cairo precompile with the given contract address, function selector and data.
    /// @param contractAddress The address of the contract to call.
    /// @param functionSelector The function selector to call.
    /// @param data The data to pass to the function.
    /// @return The result of the Cairo precompile call.
    function callCairo(uint256 contractAddress, uint256 functionSelector, uint256[] memory data)
        internal
        returns (bytes memory)
    {
        bytes memory callData = abi.encode(contractAddress, functionSelector, data);

        (bool success, bytes memory result) = WHITELISTED_CALL_CAIRO_PRECOMPILE_ADDRESS.call(callData);
        require(success, string(abi.encodePacked("CairoLib: cairo call failed with: ", result)));

        return result;
    }

    function callCairo(uint256 contractAddress, string memory functionName, uint256[] memory data)
        internal
        returns (bytes memory)
    {
        uint256 functionSelector = uint256(keccak256(bytes(functionName))) % 2 ** 250;
        return callCairo(contractAddress, functionSelector, data);
    }

    function callCairo(uint256 contractAddress, string memory functionName) internal returns (bytes memory) {
        uint256[] memory data = new uint256[](0);
        uint256 functionSelector = uint256(keccak256(bytes(functionName))) % 2 ** 250;
        return callCairo(contractAddress, functionSelector, data);
    }

    /// @notice Delegate calls the Cairo precompile with the given contract address, function selector and data.
    /// @param contractAddress The address of the contract to delegate call.
    /// @param functionName The function name to delegate call.
    /// @param data The data to pass to the function.
    /// @return The result of the Cairo precompile delegate call.
    function delegatecallCairo(uint256 contractAddress, string memory functionName, uint256[] memory data)
        internal
        returns (bytes memory)
    {
        uint256 functionSelector = uint256(keccak256(bytes(functionName))) % 2 ** 250;
        bytes memory callData = abi.encode(contractAddress, functionSelector, data);

        (bool success, bytes memory result) = WHITELISTED_CALL_CAIRO_PRECOMPILE_ADDRESS.delegatecall(callData);
        require(success, string(abi.encodePacked("CairoLib: cairo call failed with: ", result)));

        return result;
    }

    function delegatecallCairo(uint256 contractAddress, string memory functionName) internal returns (bytes memory) {
        uint256[] memory data = new uint256[](0);
        return delegatecallCairo(contractAddress, functionName, data);
    }

    /// @notice Static calls the Cairo precompile with the given contract address, function selector and data.
    /// @dev This doesn't protect against mutation of the underlying Cairo contract state.
    /// @param contractAddress The address of the contract to static call.
    /// @param functionName The function name to static call.
    /// @param data The data to pass to the function.
    /// @return The result of the Cairo precompile static call.
    function staticcallCairo(uint256 contractAddress, string memory functionName, uint256[] memory data)
        internal
        view
        returns (bytes memory)
    {
        uint256 functionSelector = uint256(keccak256(bytes(functionName))) % 2 ** 250;
        bytes memory callData = abi.encode(contractAddress, functionSelector, data);

        (bool success, bytes memory result) = WHITELISTED_CALL_CAIRO_PRECOMPILE_ADDRESS.staticcall(callData);
        require(success, string(abi.encodePacked("CairoLib: cairo call failed with: ", result)));

        return result;
    }

    function staticcallCairo(uint256 contractAddress, string memory functionName)
        internal
        view
        returns (bytes memory)
    {
        uint256[] memory data = new uint256[](0);
        return staticcallCairo(contractAddress, functionName, data);
    }
}
