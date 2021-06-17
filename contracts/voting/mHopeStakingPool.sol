// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract mHopeStakingPool is OwnableUpgradeSafe {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public reserveFund;
    address public exchangeProxy;

    uint256 private _locked = 0;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 reward;
        uint256 accumulatedEarned; // will accumulate every time user harvest
        uint256 lockReward;
        uint256 lockRewardReleased;
        uint256 lastStakeTime;
    }

    // Info of reward pool funding (usdc)
    address public rewardToken = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174); // USDC
    uint256 public lastRewardTime; // Last block number that rewardPool distribution occurs.
    uint256 public rewardPerSecond; // Reward token amount to distribute per block.
    uint256 public accRewardPerShare; // Accumulated rewardPool per share, times 1e18.
    uint256 public totalPaidRewards;

    uint256 public startRewardTime;
    uint256 public endRewardTime;

    address public stakeToken;

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address rewardToken, address indexed user, uint256 amount);

    /* ========== Modifiers =============== */

    modifier onlyExchangeProxy() {
        require(exchangeProxy == msg.sender || owner() == msg.sender, "mHopeStakingPool: caller is not the exchangeProxy");
        _;
    }

    modifier onlyReserveFund() {
        require(reserveFund == msg.sender || owner() == msg.sender, "mHopeStakingPool: caller is not the reserveFund");
        _;
    }

    modifier lock() {
        require(_locked == 0, 'mHopeStakingPool: LOCKED');
        _locked = 1;
        _;
        _locked = 0;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _stakeToken, address _rewardToken, uint256 _startRewardTime) public initializer {
        require(now < _startRewardTime, "late");
        OwnableUpgradeSafe.__Ownable_init();

        stakeToken = _stakeToken;
        rewardToken = _rewardToken;

        startRewardTime = _startRewardTime;
        endRewardTime = _startRewardTime;

        _locked = 0;

        lastRewardTime = _startRewardTime;
        rewardPerSecond = 0;
        accRewardPerShare = 0;
        totalPaidRewards = 0;
    }

    function setExchangeProxy(address _exchangeProxy) external onlyExchangeProxy {
        exchangeProxy = _exchangeProxy;
    }

    function setReserveFund(address _reserveFund) external onlyReserveFund {
        reserveFund = _reserveFund;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getRewardPerSecond(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 _rewardPerSecond = rewardPerSecond;
        if (_from >= _to || _from >= endRewardTime) return 0;
        if (_to <= startRewardTime) return 0;
        if (_from <= startRewardTime) {
            if (_to <= endRewardTime) return _to.sub(startRewardTime).mul(_rewardPerSecond);
            else return endRewardTime.sub(startRewardTime).mul(_rewardPerSecond);
        }
        if (_to <= endRewardTime) return _to.sub(_from).mul(_rewardPerSecond);
        else return endRewardTime.sub(_from).mul(_rewardPerSecond);
    }

    function getRewardPerSecond() external view returns (uint256) {
        return getRewardPerSecond(now, now + 1);
    }

    function pendingReward(address _account) external view returns (uint256) {
        UserInfo storage user = userInfo[_account];
        uint256 _accRewardPerShare = accRewardPerShare;
        uint256 lpSupply = IERC20(stakeToken).balanceOf(address(this));
        uint256 _endRewardTime = endRewardTime;
        uint256 _endRewardTimeApplicable = now > _endRewardTime ? _endRewardTime : now;
        uint256 _lastRewardTime = lastRewardTime;
        if (_endRewardTimeApplicable > _lastRewardTime && lpSupply != 0) {
            uint256 _incRewardPerShare = getRewardPerSecond(_lastRewardTime, _endRewardTimeApplicable).mul(1e18).div(lpSupply);
            _accRewardPerShare = _accRewardPerShare.add(_incRewardPerShare);
        }
        return user.amount.mul(_accRewardPerShare).div(1e18).add(user.reward).sub(user.rewardDebt);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function allocateMoreRewards(uint256 _addedReward, uint256 _days) external onlyReserveFund {
        uint256 _pendingSeconds = (endRewardTime > now) ? endRewardTime.sub(now) : 0;
        if (_pendingSeconds > 0 || _days > 0) {
            updateReward();
            IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), _addedReward);
            uint256 _newPendingReward = rewardPerSecond.mul(_pendingSeconds).add(_addedReward);
            uint256 _newPendingSeconds = _pendingSeconds.add(_days.mul(1 days));
            rewardPerSecond = _newPendingReward.div(_newPendingSeconds);
        }
        if (_days > 0) {
            if (endRewardTime < now) {
                endRewardTime = now.add(_days.mul(1 days));
            } else {
                endRewardTime = endRewardTime.add(_days.mul(1 days));
            }
        }
    }

    function updateReward() public {
        uint256 _endRewardTime = endRewardTime;
        uint256 _endRewardTimeApplicable = now > _endRewardTime ? _endRewardTime : now;
        uint256 _lastRewardTime = lastRewardTime;
        if (_endRewardTimeApplicable > _lastRewardTime) {
            uint256 lpSupply = IERC20(stakeToken).balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 _incRewardPerShare = getRewardPerSecond(_lastRewardTime, _endRewardTimeApplicable).mul(1e18).div(lpSupply);
                accRewardPerShare = accRewardPerShare.add(_incRewardPerShare);
            }
            lastRewardTime = _endRewardTimeApplicable;
        }
    }

    // Deposit LP tokens
    function _deposit(address _account, uint256 _amount) internal lock {
        UserInfo storage user = userInfo[_account];
        getReward(_account);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(accRewardPerShare).div(1e18);
        emit Deposit(_account, _amount);
    }

    function deposit(uint256 _amount) external {
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), _amount);
        _deposit(msg.sender, _amount);
    }

    function depositFor(address _account, uint256 _amount) external onlyExchangeProxy {
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), _amount);
        _deposit(_account, _amount);
    }

    // Withdraw LP tokens.
    function _withdraw(address _account, uint256 _amount) internal lock {
        UserInfo storage user = userInfo[_account];
        getReward(_account);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            IERC20(stakeToken).safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount.mul(accRewardPerShare).div(1e18);
        emit Withdraw(_account, _amount);
    }

    function withdraw(uint256 _amount) external {
        _withdraw(msg.sender, _amount);
    }

    function claimReward() external {
        getReward(msg.sender);
    }

    function getReward(address _account) public {
        updateReward();
        UserInfo storage user = userInfo[_account];
        uint256 _accRewardPerShare = accRewardPerShare;
        uint256 _pendingReward = user.amount.mul(_accRewardPerShare).div(1e18).sub(user.rewardDebt);
        if (_pendingReward > 0) {
            address _rewardToken = rewardToken;
            user.accumulatedEarned = user.accumulatedEarned.add(_pendingReward);
            user.rewardDebt = user.amount.mul(_accRewardPerShare).div(1e18);
            uint256 _paidAmount = user.reward.add(_pendingReward);
            // Safe reward transfer, just in case if rounding error causes pool to not have enough reward amount
            uint256 _rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
            if (_rewardBalance < _paidAmount) {
                user.reward = _paidAmount; // pending, dont claim yet
            } else {
                user.reward = 0;
                totalPaidRewards = totalPaidRewards.add(_paidAmount);
                _safeTokenTransfer(_rewardToken, _account, _paidAmount);
                emit RewardPaid(_rewardToken, _account, _paidAmount);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() external lock {
        UserInfo storage user = userInfo[msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.reward = 0;
        IERC20(stakeToken).safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _amount);
    }

    function _safeTokenTransfer(address _token, address _to, uint256 _amount) internal {
        uint256 _tokenBal = IERC20(_token).balanceOf(address(this));
        if (_amount > _tokenBal) {
            _amount = _tokenBal;
        }
        if (_amount > 0) {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }
}