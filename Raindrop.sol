// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RaindropEscrow
 * @dev Smart contract for escrowing tokens and executing batch transfers for raindrops
 * Solves multiple issues:
 * 1. Funds are locked at scheduling time (no balance changes during 24h window)
 * 2. Batch transfers in single transaction (gas optimization)
 * 3. Atomic execution (all or nothing, or partial with rollback)
 * 4. Participant limits and validation
 */
contract RaindropEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Maximum participants to prevent gas limit issues
    uint256 public constant MAX_PARTICIPANTS = 1000;
    
    // Minimum amount per participant (in wei/smallest unit)
    uint256 public constant MIN_AMOUNT_PER_PARTICIPANT = 1000; // Adjust based on token
    
    // Platform fee (0.1% = 10 basis points)
    uint256 public platformFeeBps = 10;
    address public feeRecipient;

    struct Raindrop {
        string raindropId;
        address host;
        address token;
        uint256 totalAmount;
        uint256 scheduledTime;
        bool executed;
        bool cancelled;
        uint256 participantCount;
        mapping(address => bool) participants;
        address[] participantList;
    }

    mapping(string => Raindrop) public raindrops;
    mapping(string => bool) public raindropExists;

    event RaindropCreated(
        string indexed raindropId,
        address indexed host,
        address indexed token,
        uint256 totalAmount,
        uint256 scheduledTime
    );

    event RaindropExecuted(
        string indexed raindropId,
        uint256 participantCount,
        uint256 amountPerParticipant,
        uint256 totalDistributed
    );

    event RaindropCancelled(
        string indexed raindropId,
        address indexed host,
        uint256 refundAmount
    );

    event ParticipantsUpdated(
        string indexed raindropId,
        uint256 participantCount
    );

    constructor(address _feeRecipient) Ownable (msg.sender){
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Create and fund a raindrop escrow
     * @param raindropId Unique identifier for the raindrop
     * @param token Token address to distribute
     * @param totalAmount Total amount to distribute
     * @param scheduledTime When the raindrop should execute (timestamp)
     */
    function createRaindrop(
        string calldata raindropId,
        address token,
        uint256 totalAmount,
        uint256 scheduledTime
    ) external nonReentrant {
        require(!raindropExists[raindropId], "Raindrop already exists");
        require(token != address(0), "Invalid token address");
        require(totalAmount > 0, "Amount must be greater than 0");
        require(scheduledTime > block.timestamp, "Scheduled time must be in future");

        // Transfer tokens to escrow
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        // Create raindrop struct
        Raindrop storage newRaindrop = raindrops[raindropId];
        newRaindrop.raindropId = raindropId;
        newRaindrop.host = msg.sender;
        newRaindrop.token = token;
        newRaindrop.totalAmount = totalAmount;
        newRaindrop.scheduledTime = scheduledTime;
        newRaindrop.executed = false;
        newRaindrop.cancelled = false;
        newRaindrop.participantCount = 0;

        raindropExists[raindropId] = true;

        emit RaindropCreated(raindropId, msg.sender, token, totalAmount, scheduledTime);
    }

    /**
     * @dev Update participants list (can be called multiple times before execution)
     * @param raindropId The raindrop to update
     * @param participants Array of participant addresses
     */
    function updateParticipants(
        string calldata raindropId,
        address[] calldata participants
    ) external {
        require(raindropExists[raindropId], "Raindrop does not exist");
        
        Raindrop storage raindrop = raindrops[raindropId];
        require(msg.sender == raindrop.host || msg.sender == owner(), "Not authorized");
        require(!raindrop.executed, "Raindrop already executed");
        require(!raindrop.cancelled, "Raindrop cancelled");
        require(participants.length <= MAX_PARTICIPANTS, "Too many participants");

        // Clear existing participants
        for (uint256 i = 0; i < raindrop.participantList.length; i++) {
            raindrop.participants[raindrop.participantList[i]] = false;
        }
        delete raindrop.participantList;

        // Add new participants
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            require(participant != address(0), "Invalid participant address");
            require(participant != raindrop.host, "Host cannot be participant");
            
            if (!raindrop.participants[participant]) {
                raindrop.participants[participant] = true;
                raindrop.participantList.push(participant);
            }
        }

        raindrop.participantCount = raindrop.participantList.length;

        // Validate minimum amount per participant
        if (raindrop.participantCount > 0) {
            uint256 amountPerParticipant = raindrop.totalAmount / raindrop.participantCount;
            require(amountPerParticipant >= MIN_AMOUNT_PER_PARTICIPANT, 
                   "Amount per participant too small");
        }

        emit ParticipantsUpdated(raindropId, raindrop.participantCount);
    }

    /**
     * @dev Execute the raindrop batch transfer
     * @param raindropId The raindrop to execute
     */
    function executeRaindrop(string calldata raindropId) external nonReentrant {
        require(raindropExists[raindropId], "Raindrop does not exist");
        
        Raindrop storage raindrop = raindrops[raindropId];
        require(msg.sender == raindrop.host || msg.sender == owner(), "Not authorized");
        require(!raindrop.executed, "Raindrop already executed");
        require(!raindrop.cancelled, "Raindrop cancelled");
        require(block.timestamp >= raindrop.scheduledTime, "Too early to execute");
        require(raindrop.participantCount > 0, "No participants");

        // Mark as executed first to prevent reentrancy
        raindrop.executed = true;

        uint256 amountPerParticipant = raindrop.totalAmount / raindrop.participantCount;
        uint256 totalToDistribute = amountPerParticipant * raindrop.participantCount;
        
        // Calculate platform fee
        uint256 platformFee = (totalToDistribute * platformFeeBps) / 10000;
        uint256 remainingAmount = raindrop.totalAmount - totalToDistribute - platformFee;

        IERC20 token = IERC20(raindrop.token);

        // Batch transfer to all participants
        for (uint256 i = 0; i < raindrop.participantCount; i++) {
            address participant = raindrop.participantList[i];
            token.safeTransfer(participant, amountPerParticipant);
        }

        // Transfer platform fee
        if (platformFee > 0) {
            token.safeTransfer(feeRecipient, platformFee);
        }

        // Refund any remaining amount to host (from rounding)
        if (remainingAmount > 0) {
            token.safeTransfer(raindrop.host, remainingAmount);
        }

        emit RaindropExecuted(raindropId, raindrop.participantCount, amountPerParticipant, totalToDistribute);
    }

    /**
     * @dev Cancel a raindrop and refund tokens to host
     * @param raindropId The raindrop to cancel
     */
    function cancelRaindrop(string calldata raindropId) external nonReentrant {
        require(raindropExists[raindropId], "Raindrop does not exist");
        
        Raindrop storage raindrop = raindrops[raindropId];
        require(msg.sender == raindrop.host || msg.sender == owner(), "Not authorized");
        require(!raindrop.executed, "Raindrop already executed");
        require(!raindrop.cancelled, "Raindrop already cancelled");

        raindrop.cancelled = true;

        // Refund tokens to host
        IERC20(raindrop.token).safeTransfer(raindrop.host, raindrop.totalAmount);

        emit RaindropCancelled(raindropId, raindrop.host, raindrop.totalAmount);
    }

    /**
     * @dev Get raindrop details
     */
    function getRaindropDetails(string calldata raindropId) 
        external 
        view 
        returns (
            address host,
            address token,
            uint256 totalAmount,
            uint256 scheduledTime,
            bool executed,
            bool cancelled,
            uint256 participantCount
        ) 
    {
        require(raindropExists[raindropId], "Raindrop does not exist");
        
        Raindrop storage raindrop = raindrops[raindropId];
        return (
            raindrop.host,
            raindrop.token,
            raindrop.totalAmount,
            raindrop.scheduledTime,
            raindrop.executed,
            raindrop.cancelled,
            raindrop.participantCount
        );
    }

    /**
     * @dev Get participants list
     */
    function getParticipants(string calldata raindropId) 
        external 
        view 
        returns (address[] memory) 
    {
        require(raindropExists[raindropId], "Raindrop does not exist");
        return raindrops[raindropId].participantList;
    }

    /**
     * @dev Update platform fee (only owner)
     */
    function updatePlatformFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        platformFeeBps = newFeeBps;
    }

    /**
     * @dev Update fee recipient (only owner)
     */
    function updateFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), "Invalid address");
        feeRecipient = newFeeRecipient;
    }

    /**
     * @dev Emergency function to recover stuck tokens (only owner)
     */
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
