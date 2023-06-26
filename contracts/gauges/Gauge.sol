// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReward} from "../interfaces/IReward.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {VelodromeTimeLibrary} from "../libraries/VelodromeTimeLibrary.sol";

/// @title Gauge contract for distribution of emissions by address
contract Gauge is IGauge, ERC2771Context, ReentrancyGuard { // @audit ERC2771Context use _msgSender() instead of msg.sender, use ReentrancyGuard instead of lock modifier
    using SafeERC20 for IERC20;
    address public immutable stakingToken; // the LP token that needs to be staked for rewards
    address public immutable rewardToken;
    address public immutable feesVotingReward;
    address public immutable voter;

    bool public immutable isPool;

    uint256 internal constant DURATION = 7 days; // rewards are released over 7 days
    uint256 internal constant PRECISION = 10 ** 18;

    // default snx staking contract implementation: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(uint256 => uint256) public rewardRateByEpoch; // epochStart => rewardRate

    uint256 public fees0;
    uint256 public fees1;

    constructor(
        address _forwarder,
        address _stakingToken,
        address _feesVotingReward,
        address _rewardToken,
        address _voter,
        bool _isPool
    ) ERC2771Context(_forwarder) {
        stakingToken = _stakingToken;
        feesVotingReward = _feesVotingReward;
        rewardToken = _rewardToken;
        voter = _voter;
        isPool = _isPool;
    }

    function _claimFees() internal returns (uint256 claimed0, uint256 claimed1) { // @audit-info from old gauge contract use ipool instead of ipair 
        if (!isPool) {
            return (0, 0);
        }
        (claimed0, claimed1) = IPool(stakingToken).claimFees(); // @audit-info called only by voter address
        if (claimed0 > 0 || claimed1 > 0) {
            uint256 _fees0 = fees0 + claimed0;
            uint256 _fees1 = fees1 + claimed1;
            (address _token0, address _token1) = IPool(stakingToken).tokens();
            if (_fees0 > DURATION) { // @audit use constant instead of internal_bribe.left value
                fees0 = 0;
                IERC20(_token0).safeApprove(feesVotingReward, _fees0);
                IReward(feesVotingReward).notifyRewardAmount(_token0, _fees0); // renamed from IBribe(internal_bribe)
            } else {
                fees0 = _fees0;
            }
            if (_fees1 > DURATION) { // @audit use constant instead of internal_bribe.left value
                fees1 = 0;
                IERC20(_token1).safeApprove(feesVotingReward, _fees1);
                IReward(feesVotingReward).notifyRewardAmount(_token1, _fees1);
            } else {
                fees1 = _fees1;
            }

            emit ClaimFees(_msgSender(), claimed0, claimed1); // @audit use _msgSender() instead of msg.sender
        }
    }

    function rewardPerToken() public view returns (uint256) { // @audit-ok the same as in snx staking contract: https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) /
            totalSupply;
    }

    function lastTimeRewardApplicable() public view returns (uint256) { // @audit-ok don't have param token but single periodFinish for all tokens
        return Math.min(block.timestamp, periodFinish);
    }

    /// @inheritdoc IGauge
    function getReward(address _account) external nonReentrant { // @audit-info only voter can call for any account
        address sender = _msgSender();
        if (sender != _account && sender != voter) revert NotAuthorized(); // @audit-issue voter can bypass this check and call getReward for any account, strange thing to do, why not use msgSender instead?

        _updateRewards(_account); // @audit-info updates the values

        uint256 reward = rewards[_account]; // @audit-ok the same is in snx staking contract
        if (reward > 0) {
            rewards[_account] = 0;
            IERC20(rewardToken).safeTransfer(_account, reward);
            emit ClaimRewards(_account, reward);
        }
    }

    /// @inheritdoc IGauge
    function earned(address _account) public view returns (uint256) { // @audit-ok the same is in snx staking contract
        return
            (balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) /
            PRECISION +
            rewards[_account];
    }

    /// @inheritdoc IGauge
    function deposit(uint256 _amount) external {
        _depositFor(_amount, _msgSender()); // @audit-info nonReentrant in implementation
    }

    /// @inheritdoc IGauge
    function deposit(uint256 _amount, address _recipient) external {
        _depositFor(_amount, _recipient); // @audit-info nonReentrant in implementation
    }

    function _depositFor(uint256 _amount, address _recipient) internal nonReentrant { // @audit-ok
        if (_amount == 0) revert ZeroAmount();
        if (!IVoter(voter).isAlive(address(this))) revert NotAlive();

        address sender = _msgSender();
        _updateRewards(_recipient);

        IERC20(stakingToken).safeTransferFrom(sender, address(this), _amount);
        totalSupply += _amount;
        balanceOf[_recipient] += _amount;

        emit Deposit(sender, _recipient, _amount);
    }

    /// @inheritdoc IGauge
    function withdraw(uint256 _amount) external nonReentrant { // @audit-ok
        address sender = _msgSender();

        _updateRewards(sender);

        totalSupply -= _amount;
        balanceOf[sender] -= _amount;
        IERC20(stakingToken).safeTransfer(sender, _amount);

        emit Withdraw(sender, _amount);
    }

    function _updateRewards(address _account) internal { // @audit-ok logic is the same as in snx staking contract
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewards[_account] = earned(_account);
        userRewardPerTokenPaid[_account] = rewardPerTokenStored;
    }

    function left() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        uint256 _remaining = periodFinish - block.timestamp;
        return _remaining * rewardRate;
    }

    /// @inheritdoc IGauge
    function notifyRewardAmount(uint256 _amount) external nonReentrant { // @audit looking good, similiar to snx staking contract
        address sender = _msgSender();
        if (sender != voter) revert NotVoter();
        if (_amount == 0) revert ZeroAmount();
        _claimFees();
        rewardPerTokenStored = rewardPerToken(); // @audit-info updates values from snx modifier updateReward(address _account)
        uint256 timestamp = block.timestamp;
        uint256 timeUntilNext = VelodromeTimeLibrary.epochNext(timestamp) - timestamp;

        if (timestamp >= periodFinish) { // @audit-info reward period finished
            IERC20(rewardToken).safeTransferFrom(sender, address(this), _amount);
            rewardRate = _amount / timeUntilNext;
        } else {
            uint256 _remaining = periodFinish - timestamp;
            uint256 _leftover = _remaining * rewardRate;
            IERC20(rewardToken).safeTransferFrom(sender, address(this), _amount);
            rewardRate = (_amount + _leftover) / timeUntilNext;
        }
        rewardRateByEpoch[VelodromeTimeLibrary.epochStart(timestamp)] = rewardRate; // @audit-info can be manipulated by seting high rewardRate at the end
        if (rewardRate == 0) revert ZeroRewardRate();

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (rewardRate > balance / timeUntilNext) revert RewardRateTooHigh();

        lastUpdateTime = timestamp;
        periodFinish = timestamp + timeUntilNext;
        emit NotifyReward(sender, _amount);
    }
}
