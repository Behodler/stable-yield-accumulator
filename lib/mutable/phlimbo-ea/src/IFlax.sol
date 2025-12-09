// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFlax
 * @notice Interface for Flax token (phUSD) with minting capabilities
 */
interface IFlax is IERC20 {
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }

    function mint(address recipient, uint256 amount) external;
    function burn(address holder, uint256 amount) external;
    function authorizedMinters(address minter) external view returns (MinterInfo memory);
    function mintVersion() external view returns (uint256);
    function revokeAllMintPrivileges() external;
}
