// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Owned } from "@solmate/auth/Owned.sol";


/// @dev A token inheriting from MultiERC20Rewards will reward token holders with 0 to MAX_REWARD_TOKENS reward tokens.
/// The rewarded amount will be a fixed wei per second, distributed proportionally to token holders
/// by the size of their holdings.
contract MultiERC20Rewards is Owned, ERC20 {
    using SafeTransferLib for ERC20;
    using Cast for uint256;

    event RewardsSet(uint32 start, uint32 end, uint256 rate);
    event RewardTokenAdded(address token);
    event RewardsPerTokenUpdated(address token, uint256 accumulated);
    event UserRewardsUpdated(address token, address user, uint256 userRewards, uint256 paidRewardPerToken);
    event Claimed(address token, address user, address receiver, uint256 claimed);

    struct RewardsInterval {
        uint32 start;                                   // Start time for the current rewardsToken schedule
        uint32 end;                                     // End time for the current rewardsToken schedule
        uint96 rate;                                    // Wei rewarded per second among all token holders
    }

    struct RewardsPerToken {
        uint128 accumulated;                            // Accumulated rewards per token for the interval, scaled up by 1e18
        uint32 lastUpdated;                             // Last time the rewards per token accumulator was updated
    }

    struct UserRewards {
        uint128 accumulated;                            // Accumulated rewards for the user until the checkpoint
        uint128 checkpoint;                             // RewardsPerToken the last time the user rewards were updated
    }

    uint256 public constant MAX_REWARD_TOKENS = 10;                // Maximum number of reward tokens, important to prevent a gas DoS attack

    ERC20[] public rewardTokens;                                   // Tokens used as rewards
    uint8 public rewardTokensCount;                                // Number of rewards tokens
    mapping(address => RewardsInterval) public tokenToRewardsInterval;                         // Interval in which rewards are accumulated by users
    mapping(address => RewardsPerToken) public tokenToRewardsPerToken;                         // Accumulator to track rewards per token
    mapping(address => mapping (address => UserRewards)) public tokenToAccumulatedRewards;     // Rewards accumulated per user
    
    constructor(address _owner, /* ERC20 rewardsToken_, */ string memory name, string memory symbol, uint8 decimals)
        ERC20(name, symbol, decimals)
        Owned(_owner)
    {
        // rewardsToken = rewardsToken_;
        rewardTokensCount = 0;
    }

    /// @dev Add a new rewards token
    function addRewardToken(ERC20 rewardToken) external onlyOwner {
        require(rewardTokensCount != MAX_REWARD_TOKENS, "Max # of reward tokens reached");
        rewardTokens.push(rewardToken);
        rewardTokensCount++;
        emit RewardTokenAdded(address(rewardToken));
    }

    /// @dev Set a rewards schedule
    function setRewardsInterval(address token, uint256 start, uint256 end, uint256 totalRewards)
        external
        onlyOwner
    {
        require(
            start < end,
            "Incorrect interval"
        );

        RewardsInterval rewardsInterval = tokenToRewardsInterval[token];

        // A new rewards program can be set if one is not running
        require(
            block.timestamp.u32() < rewardsInterval.start || block.timestamp.u32() > rewardsInterval.end,
            "Rewards still ongoing"
        );

        // Update the rewards per token so that we don't lose any rewards
        _updateRewardsPerToken(token);

        uint256 rate = totalRewards / (end - start);  
        rewardsInterval.start = start.u32();
        rewardsInterval.end = end.u32();
        rewardsInterval.rate = rate.u96();

        // If setting up a new rewards program, the rewardsPerToken.accumulated is used and built upon
        // New rewards start accumulating from the new rewards program start
        // Any unaccounted rewards from last program can still be added to the user rewards
        // Any unclaimed rewards can still be claimed
        tokenToRewardsPerToken[token].lastUpdated = start.u32();

        emit RewardsSet(start.u32(), end.u32(), rate);
    }


    /// @notice Update the rewards per token accumulator according to the rate, the time elapsed since the last update, and the current total staked amount.
    function _calculateRewardsPerToken(address token, RewardsPerToken memory rewardsPerTokenIn, RewardsInterval memory rewardsInterval_) internal view returns(RewardsPerToken memory) {
        RewardsPerToken memory rewardsPerTokenOut = RewardsPerToken(rewardsPerTokenIn.accumulated, rewardsPerTokenIn.lastUpdated);
        uint256 totalSupply_ = totalSupply;

        // No changes if the program hasn't started
        if (block.timestamp < rewardsInterval_.start) return rewardsPerTokenOut;

        // Stop accumulating at the end of the rewards interval
        uint256 updateTime = block.timestamp < rewardsInterval_.end ? block.timestamp : rewardsInterval_.end;
        uint256 elapsed = updateTime - rewardsPerTokenIn.lastUpdated;
        
        // No changes if no time has passed
        if (elapsed == 0) return rewardsPerTokenOut;
        rewardsPerTokenOut.lastUpdated = updateTime.u32();
        
        // If there are no stakers we just change the last update time, the rewards for intervals without stakers are not accumulated
        if (totalSupply_ == 0) return rewardsPerTokenOut;

        // Calculate and update the new value of the accumulator.
        rewardsPerTokenOut.accumulated = (rewardsPerTokenIn.accumulated + 1e18 * elapsed * rewardsInterval_.rate  / totalSupply_).u128(); // The rewards per token are scaled up for precision
        return rewardsPerTokenOut;
    }

    /// @notice Calculate the rewards accumulated by a stake between two checkpoints.
    function _calculateUserRewards(uint256 stake_, uint256 earlierCheckpoint, uint256 latterCheckpoint) internal pure returns (uint256) {
        return stake_ * (latterCheckpoint - earlierCheckpoint) / 1e18; // We must scale down the rewards by the precision factor
    }

    /// @notice Update and return the rewards per token accumulator according to the rate, the time elapsed since the last update, and the current total staked amount.
    function _updateRewardsPerToken(address token) internal returns (RewardsPerToken memory){
        RewardsPerToken memory rewardsPerTokenIn = tokenToRewardsPerToken[token];
        RewardsPerToken memory rewardsPerTokenOut = _calculateRewardsPerToken(rewardsPerTokenIn, rewardsInterval);

        // We skip the storage changes if already updated in the same block, or if the program has ended and was updated at the end
        if (rewardsPerTokenIn.lastUpdated == rewardsPerTokenOut.lastUpdated) return rewardsPerTokenOut;

        tokenToRewardsPerToken[token] = rewardsPerTokenOut;
        emit RewardsPerTokenUpdated(token, rewardsPerTokenOut.accumulated);

        return rewardsPerTokenOut;
    }

    /// @notice Calculate and store current rewards for an user. Checkpoint the rewardsPerToken value with the user.
    function _updateUserRewards(address token, address user) internal returns (UserRewards memory) {
        RewardsPerToken memory rewardsPerToken_ = _updateRewardsPerToken(token);
        UserRewards memory userRewards_ = tokenToAccumulatedRewards[token][user];

        // We skip the storage changes if there are no changes to the rewards per token accumulator
        if (userRewards_.checkpoint == rewardsPerToken_.accumulated) return userRewards_;
        
        // Calculate and update the new value user reserves.
        userRewards_.accumulated += _calculateUserRewards(balanceOf[user], userRewards_.checkpoint, rewardsPerToken_.accumulated).u128();
        userRewards_.checkpoint = rewardsPerToken_.accumulated;

        tokenToAccumulatedRewards[token][user] = userRewards_;
        emit UserRewardsUpdated(user, userRewards_.accumulated, userRewards_.checkpoint);

        return userRewards_;
    }

    /// @dev Mint tokens, after accumulating rewards for an user and update the rewards per token accumulator.
    function _mint(address to, uint256 amount)
        internal virtual override
    {
        for (uint8 i = 0; i < rewardTokensCount; ++i)
            _updateUserRewards(rewardTokens[i], to);
        super._mint(to, amount);
    }

    /// @dev Burn tokens, after accumulating rewards for an user and update the rewards per token accumulator.
    function _burn(address from, uint256 amount)
        internal virtual override
    {
        for (uint8 i = 0; i < rewardTokensCount; ++i)
            _updateUserRewards(rewardTokens[i], from);
        super._burn(from, amount);
    }

    /// @notice Claim rewards for an user
    function _claim(address token, address from, address to, uint256 amount) internal virtual {
        _updateUserRewards(token, from);
        tokenToAccumulatedRewards[token][from].accumulated -= amount.u128();
        ERC20(token).safeTransfer(to, amount);
        emit Claimed(token, from, to, amount);
    }

    /// @dev Transfer tokens, after updating rewards for source and destination.
    function transfer(address to, uint amount) public virtual override returns (bool) {
        for (uint8 i = 0; i < rewardTokensCount; ++i) {
            address token = address(rewardTokens[i]);
            _updateUserRewards(msg.sender);
            _updateUserRewards(to);
        }
        return super.transfer(to, amount);
    }

    /// @dev Transfer tokens, after updating rewards for source and destination.
    function transferFrom(address from, address to, uint amount) public virtual override returns (bool) {
        for (uint8 i = 0; i < rewardTokensCount; ++i) {
            address token = address(rewardTokens[i]);
            _updateUserRewards(token, from);
            _updateUserRewards(token, to);
        }
        return super.transferFrom(from, to, amount);
    }

    /// @notice Claim all of one reward token for the caller
    function claim(address token, address to) public virtual returns (uint256) {
        uint256 claimed = currentUserRewards(token, msg.sender);
        _claim(token, msg.sender, to, claimed);

        return claimed;
    }

    /// @notice Claim all of one reward token for any user
    function claim(address token, address user) public virtual returns (uint256) {
        uint256 claimed = currentUserRewards(token, user);
        _claim(token, user, user, claimed);

        return claimed;
    }

    /// @notice Calculate and return current rewards per token.
    function currentRewardsPerToken(address token) public view returns (uint256) {
        return _calculateRewardsPerToken(tokenToRewardsPerToken[token], tokenToRewardsInterval[token]).accumulated;
    }

    /// @notice Calculate and return current rewards for a user.
    function currentUserRewards(address token, address user) public view returns (uint256) {
    /// @dev This repeats the logic used on transactions, but doesn't update the storage.
        UserRewards memory accumulatedRewards_ = tokenToAccumulatedRewards[token][user];
        RewardsPerToken memory rewardsPerToken_ = _calculateRewardsPerToken(tokenToRewardsPerToken[token], tokenToRewardsInterval[token]);
        return accumulatedRewards_.accumulated + _calculateUserRewards(balanceOf[user], accumulatedRewards_.checkpoint, rewardsPerToken_.accumulated);
    }
}

library Cast {
    function u128(uint256 x) internal pure returns (uint128 y) {
        require(x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }

    function u96(uint256 x) internal pure returns (uint96 y) {
        require(x <= type(uint96).max, "Cast overflow");
        y = uint96(x);
    }

    function u32(uint256 x) internal pure returns (uint32 y) {
        require(x <= type(uint32).max, "Cast overflow");
        y = uint32(x);
    }
}