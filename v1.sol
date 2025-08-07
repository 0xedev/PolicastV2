// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract PolicastMarket is Ownable, ReentrancyGuard, AccessControl {
    bytes32 public constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 public constant QUESTION_RESOLVE_ROLE = keccak256("QUESTION_RESOLVE_ROLE");

    enum MarketOutcome {
        UNRESOLVED,
        OPTION_A,
        OPTION_B
    }

    struct Market {
        string question;
        uint256 endTime;
        MarketOutcome outcome;
        string optionA;
        string optionB;
        uint256 totalOptionAShares;
        uint256 totalOptionBShares;
        bool resolved;
        mapping(address => uint256) optionASharesBalance;
        mapping(address => uint256) optionBSharesBalance;
        mapping(address => bool) hasClaimed;
        address[] participants;
        uint256 payoutIndex;
    }

    struct Vote {
        uint256 marketId;
        bool isOptionA;
        uint256 amount;
        uint256 timestamp;
    }

    struct LeaderboardEntry {
        address user;
        uint256 totalWinnings;
        uint256 voteCount;
    }

    IERC20 public bettingToken;
    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(address => uint256) public totalSharesPurchased;
    mapping(address => uint256) public totalWinnings; // New: Tracks total winnings per user
    mapping(address => Vote[]) public voteHistory;
    address[] public allParticipants;

    event MarketCreated(uint256 indexed marketId, string question, string optionA, string optionB, uint256 endTime);
    event QuestionCreatorRoleGranted(address indexed account);
    event QuestionResolveRoleGranted(address indexed account);
    event MarketResolved(uint256 indexed marketId, MarketOutcome outcome);
    event MarketResolvedDetailed(uint256 indexed marketId, MarketOutcome outcome, uint256 totalOptionAShares, uint256 totalOptionBShares, uint256 participantsLength);

    event SharesPurchased(uint256 indexed marketId, address indexed buyer, bool isOptionA, uint256 amount);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);

    function _canSetOwner() internal view virtual returns (bool) {
        return msg.sender == owner();
    }

    constructor(address _bettingToken)   Ownable(msg.sender) {
        bettingToken = IERC20(_bettingToken);
      
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function grantQuestionCreatorRole(address _account) external onlyOwner {
        require(msg.sender == owner(), "Only owner can grant roles");
        grantRole(QUESTION_CREATOR_ROLE, _account);
        emit QuestionCreatorRoleGranted(_account);
    }

    function grantQuestionResolveRole(address _account) external onlyOwner {
        require(msg.sender == owner(), "Only owner can grant roles");
        grantRole(QUESTION_RESOLVE_ROLE, _account);
        emit QuestionResolveRoleGranted(_account);
    }

    function createMarket(string memory _question, string memory _optionA, string memory _optionB, uint256 _duration)
        external
        returns (uint256)
    {
        require(msg.sender == owner() || hasRole(QUESTION_CREATOR_ROLE, msg.sender), "Not authorized to create markets");
        require(_duration > 0, "Duration must be greater than 0");
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(bytes(_optionA).length > 0 && bytes(_optionB).length > 0, "Options cannot be empty");

        uint256 marketId = marketCount++;
        Market storage market = markets[marketId];
        market.question = _question;
        market.optionA = _optionA;
        market.optionB = _optionB;
        market.endTime = block.timestamp + _duration;
        market.outcome = MarketOutcome.UNRESOLVED;

        emit MarketCreated(marketId, _question, _optionA, _optionB, market.endTime);
        return marketId;
    }

    function buyShares(uint256 _marketId, bool _isOptionA, uint256 _amount) external nonReentrant {
        Market storage market = markets[_marketId];
        require(block.timestamp < market.endTime, "Market trading period has ended");
        require(!market.resolved, "Market already resolved");
        require(_amount > 0, "Amount must be positive");
        require(bettingToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        if (market.optionASharesBalance[msg.sender] == 0 && market.optionBSharesBalance[msg.sender] == 0) {
            market.participants.push(msg.sender);
            if (totalSharesPurchased[msg.sender] == 0) {
                allParticipants.push(msg.sender);
            }
        }

        if (_isOptionA) {
            market.optionASharesBalance[msg.sender] += _amount;
            market.totalOptionAShares += _amount;
        } else {
            market.optionBSharesBalance[msg.sender] += _amount;
            market.totalOptionBShares += _amount;
        }

        totalSharesPurchased[msg.sender] += _amount;
        voteHistory[msg.sender].push(Vote({
            marketId: _marketId,
            isOptionA: _isOptionA,
            amount: _amount,
            timestamp: block.timestamp
        }));

        emit SharesPurchased(_marketId, msg.sender, _isOptionA, _amount);
    }

    function resolveMarket(uint256 _marketId, MarketOutcome _outcome) external {
        require(msg.sender == owner() || hasRole(QUESTION_RESOLVE_ROLE, msg.sender), "Not authorized to resolve markets");
        Market storage market = markets[_marketId];
        require(block.timestamp >= market.endTime, "Market has not ended yet");
        require(!market.resolved, "Market is already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        market.outcome = _outcome;
        market.resolved = true;
        emit MarketResolvedDetailed(_marketId, _outcome, market.totalOptionAShares, market.totalOptionBShares, market.participants.length);

    }

    function distributeWinningsBatch(uint256 _marketId, uint256 batchSize) external nonReentrant {
        Market storage market = markets[_marketId];
        require(msg.sender == owner() || hasRole(QUESTION_RESOLVE_ROLE, msg.sender), "Not authorized to resolve markets");
        require(market.resolved, "Market not resolved yet");

        uint256 totalParticipants = market.participants.length;
        uint256 payoutEnd = market.payoutIndex + batchSize;
        if (payoutEnd > totalParticipants) {
            payoutEnd = totalParticipants;
        }

        uint256 winningShares = market.outcome == MarketOutcome.OPTION_A ? market.totalOptionAShares : market.totalOptionBShares;
        uint256 losingShares = market.outcome == MarketOutcome.OPTION_A ? market.totalOptionBShares : market.totalOptionAShares;
        require(winningShares > 0, "No winning shares");

        uint256 rewardRatio = (losingShares * 1e18) / winningShares;

        for (uint256 i = market.payoutIndex; i < payoutEnd; i++) {
            address user = market.participants[i];
            uint256 userShares = market.outcome == MarketOutcome.OPTION_A
                ? market.optionASharesBalance[user]
                : market.optionBSharesBalance[user];

            if (userShares > 0 && !market.hasClaimed[user]) {
                uint256 winnings = userShares + (userShares * rewardRatio) / 1e18;
                if (market.outcome == MarketOutcome.OPTION_A) {
                    market.optionASharesBalance[user] = 0;
                } else {
                    market.optionBSharesBalance[user] = 0;
                }
                market.hasClaimed[user] = true;
                totalWinnings[user] += winnings; // Update winnings
                require(bettingToken.transfer(user, winnings), "Transfer failed");
                emit Claimed(_marketId, user, winnings);
            }
        }
        market.payoutIndex = payoutEnd;
    }

    function getLeaderboard(uint256 start, uint256 limit) external view returns (LeaderboardEntry[] memory) {
        require(start < allParticipants.length, "Start index out of bounds");
        uint256 end = start + limit > allParticipants.length ? allParticipants.length : start + limit;
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](end - start);

        for (uint256 i = start; i < end; i++) {
            address user = allParticipants[i];
            entries[i - start] = LeaderboardEntry({
                user: user,
                totalWinnings: totalWinnings[user],
                voteCount: voteHistory[user].length
            });
        }
        return entries;
    }

    function getVoteHistory(address user, uint256 start, uint256 limit) external view returns (Vote[] memory) {
        Vote[] storage votes = voteHistory[user];
        require(start < votes.length, "Start index out of bounds");
        uint256 end = start + limit > votes.length ? votes.length : start + limit;
        Vote[] memory result = new Vote[](end - start);

        for (uint256 i = start; i < end; i++) {
            result[i - start] = votes[i];
        }
        return result;
    }

    function getVoteHistoryCount(address user) external view returns (uint256) {
        return voteHistory[user].length;
    }

    function getAllParticipantsCount() external view returns (uint256) {
        return allParticipants.length;
    }

    function getMarketInfo(uint256 _marketId)
        external
        view
        returns (
            string memory question,
            string memory optionA,
            string memory optionB,
            uint256 endTime,
            MarketOutcome outcome,
            uint256 totalOptionAShares,
            uint256 totalOptionBShares,
            bool resolved
        )
    {
        Market storage market = markets[_marketId];
        return (
            market.question,
            market.optionA,
            market.optionB,
            market.endTime,
            market.outcome,
            market.totalOptionAShares,
            market.totalOptionBShares,
            market.resolved
        );
    }

    function getShareBalance(uint256 _marketId, address _user)
        external
        view
        returns (uint256 optionAShares, uint256 optionBShares)
    {
        Market storage market = markets[_marketId];
        return (market.optionASharesBalance[_user], market.optionBSharesBalance[_user]);
    }

    function getUserClaimedStatus(uint256 _marketId, address _user) external view returns (bool) {
        Market storage market = markets[_marketId];
        return market.hasClaimed[_user];
    }

    function getMarketCount() external view returns (uint256) {
        return marketCount;
    }

    function getBettingToken() external view returns (address) {
        return address(bettingToken);
    }

    function getMarketInfoBatch(uint256[] calldata _marketIds)
        external
        view
        returns (
            string[] memory questions,
            string[] memory optionAs,
            string[] memory optionBs,
            uint256[] memory endTimes,
            MarketOutcome[] memory outcomes,
            uint256[] memory totalOptionASharesArray,
            uint256[] memory totalOptionBSharesArray,
            bool[] memory resolvedArray
        )
    {
        uint256 length = _marketIds.length;
        questions = new string[](length);
        optionAs = new string[](length);
        optionBs = new string[](length);
        endTimes = new uint256[](length);
        outcomes = new MarketOutcome[](length);
        totalOptionASharesArray = new uint256[](length);
        totalOptionBSharesArray = new uint256[](length);
        resolvedArray = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            Market storage market = markets[_marketIds[i]];
            questions[i] = market.question;
            optionAs[i] = market.optionA;
            optionBs[i] = market.optionB;
            endTimes[i] = market.endTime;
            outcomes[i] = market.outcome;
            totalOptionASharesArray[i] = market.totalOptionAShares;
            totalOptionBSharesArray[i] = market.totalOptionBShares;
            resolvedArray[i] = market.resolved;
        }
    }
}