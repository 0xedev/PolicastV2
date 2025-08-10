// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RainDrop
/// @notice Send ETH or ERC20 tokens to many recipients in one tx.
/// @dev ERC20 bulk transfer uses transferFrom, so users must approve this contract first.
contract RainDrop is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event BulkETHTransferred(address indexed sender, uint256 total, uint256 recipientsCount);
    event BulkERC20Transferred(address indexed token, address indexed sender, uint256 total, uint256 recipientsCount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);



    constructor() Ownable(msg.sender) {
}
    /// @notice Batch-send ETH to many recipients.
    /// @param recipients Array of recipient addresses.
    /// @param amounts Array of amounts corresponding to each recipient (in wei).
    /// Requirements:
    /// - `recipients.length == amounts.length`
    /// - sum(amounts) must equal msg.value
    function bulkTransferETH(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
    {
        uint256 n = recipients.length;
        require(n == amounts.length, "length-mismatch");
        uint256 total = 0;

        // calculate total
        for (uint256 i = 0; i < n; ++i) {
            total += amounts[i];
        }

        require(total == msg.value, "value-mismatch");

        // send funds
        for (uint256 i = 0; i < n; ++i) {
            (bool ok, ) = recipients[i].call{value: amounts[i]}("");
            require(ok, "eth-send-failed");
        }

        emit BulkETHTransferred(msg.sender, total, n);
    }

    /// @notice Batch-send ERC20 tokens to many recipients using transferFrom.
    /// @param token ERC20 token contract.
    /// @param recipients Array of recipient addresses.
    /// @param amounts Array of amounts corresponding to each recipient (in token units).
    /// Requirements:
    /// - caller must approve this contract for at least sum(amounts) before calling.
    function bulkTransferERC20(
        IERC20 token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant {
        uint256 n = recipients.length;
        require(n == amounts.length, "length-mismatch");

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            total += amounts[i];
        }

        // transferFrom caller -> recipients[i]
        for (uint256 i = 0; i < n; ++i) {
            token.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }

        emit BulkERC20Transferred(address(token), msg.sender, total, n);
    }

    /// @notice Owner-only: send ERC20 tokens that are already held by this contract to recipients.
    function bulkTransferERC20FromContract(
        IERC20 token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant {
        uint256 n = recipients.length;
        require(n == amounts.length, "length-mismatch");

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            total += amounts[i];
        }

        uint256 contractBal = token.balanceOf(address(this));
        require(contractBal >= total, "insufficient-contract-balance");

        for (uint256 i = 0; i < n; ++i) {
            token.safeTransfer(recipients[i], amounts[i]);
        }

        emit BulkERC20Transferred(address(token), address(this), total, n);
    }

    /// @notice Owner helper: withdraw ETH accidentally left in the contract.
    function withdrawETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(address(this).balance >= amount, "insufficient-eth");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw-failed");
        emit ETHWithdrawn(to, amount);
    }

    /// @notice Owner helper: withdraw ERC20 tokens from the contract.
    function withdrawERC20(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        token.safeTransfer(to, amount);
        emit ERC20Withdrawn(address(token), to, amount);
    }

    // allow contract to receive ETH
    receive() external payable {}
    fallback() external payable {}
}
