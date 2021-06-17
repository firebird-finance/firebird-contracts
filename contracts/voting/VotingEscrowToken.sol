// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../interfaces/ICappedMintableBurnableERC20.sol";
import "../interfaces/IVotingEscrow.sol";

contract VotingEscrowToken is ERC20UpgradeSafe, OwnableUpgradeSafe, IVotingEscrow {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // flags
    uint256 private _unlocked;

    uint256 public constant MINDAYS = 7;
    uint256 public constant MAXDAYS = 4 * 360;

    uint256 public constant MAXTIME = MAXDAYS * 1 days; // 4 years

    address public lockedToken;
    uint256 public minLockedAmount;
    uint256 public earlyWithdrawFeeRate;

    struct LockedBalance {
        uint256 amount;
        uint256 end;
    }

    mapping(address => LockedBalance) public locked;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    mapping(address => uint256) public mintedForLock;

    event Deposit(address indexed provider, uint256 value, uint256 locktime, uint256 timestamp);
    event Withdraw(address indexed provider, uint256 value, uint256 timestamp);

    modifier lock() {
        require(_unlocked == 1, "LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    function initialize(string memory _name, string memory _symbol, address _lockedToken, uint256 _minLockedAmount) public initializer {
        __ERC20_init(_name, _symbol);
        OwnableUpgradeSafe.__Ownable_init();
        lockedToken = _lockedToken;
        minLockedAmount = _minLockedAmount;
        earlyWithdrawFeeRate = 5000; // 50%
        _unlocked = 1;
    }

    function setMinLockedAmount(uint256 _minLockedAmount) external onlyOwner {
        minLockedAmount = _minLockedAmount;
    }

    function setEarlyWithdrawFeeRate(uint256 _earlyWithdrawFeeRate) external onlyOwner {
        require(_earlyWithdrawFeeRate <= 5000, "too high"); // <= 50%
        earlyWithdrawFeeRate = _earlyWithdrawFeeRate;
    }

    function burn(uint256 _amount) external {
        _burn(_msgSender(), _amount);
    }

    function locked__of(address _addr) external override view returns (uint256) {
        return locked[_addr].amount;
    }

    function locked__end(address _addr) external override view returns (uint256) {
        return locked[_addr].end;
    }

    function voting_power_unlock_time(uint256 _value, uint256 _unlock_time) public override view returns (uint256) {
        if (_unlock_time <= now) return 0;
        uint256 _lockedSeconds = _unlock_time.sub(now);
        if (_lockedSeconds >= MAXTIME) return _value;
        return _value.mul(_lockedSeconds).div(MAXTIME);
    }

    function voting_power_locked_days(uint256 _value, uint256 _days) public override view returns (uint256) {
        if (_days >= MAXDAYS) return _value;
        return _value.mul(_days).div(MAXDAYS);
    }

    function deposit_for(address _addr, uint256 _value) external override {
        require(_value >= minLockedAmount, "less than min amount");
        _deposit_for(_addr, _value, 0);
    }

    function create_lock(uint256 _value, uint256 _days) external override {
        require(_value >= minLockedAmount, "less than min amount");
        require(locked[_msgSender()].amount == 0, "Withdraw old tokens first");
        require(_days >= MINDAYS, "Voting lock can be 7 days min");
        require(_days <= MAXDAYS, "Voting lock can be 4 years max");
        _deposit_for(_msgSender(), _value, _days);
    }

    function _deposit_for(address _addr, uint256 _value, uint256 _days) internal lock {
        LockedBalance storage _locked = locked[_addr];
        uint256 _amount = _locked.amount;
        uint256 _end = _locked.end;
        uint256 _vp;
        if (_amount == 0) {
            _vp = voting_power_locked_days(_value, _days);
            _locked.amount = _value;
            _locked.end = now.add(_days * 1 days);
        } else if (_days == 0) {
            _vp = voting_power_unlock_time(_value, _end);
            _locked.amount = _amount.add(_value);
        } else {
            require(_value == 0, "Cannot increase amount and extend lock in the same time");
            _vp = voting_power_locked_days(_amount, _days);
            _locked.end = _end.add(_days * 1 days);
            require(_locked.end.sub(now) <= MAXTIME, "Cannot extend lock to more than 4 years");
        }
        require(_vp > 0, "No benefit to lock");
        if (_value > 0) {
            IERC20(lockedToken).safeTransferFrom(_msgSender(), address(this), _value);
        }
        _mint(_addr, _vp);
        mintedForLock[_addr] = mintedForLock[_addr].add(_vp);

        emit Deposit(_addr, _locked.amount, _locked.end, now);
    }

    function increase_amount(uint256 _value) external override {
        require(_value >= minLockedAmount, "less than min amount");
        _deposit_for(_msgSender(), _value, 0);
    }

    function increase_unlock_time(uint256 _days) external override {
        require(_days >= MINDAYS, "Voting lock can be 7 days min");
        require(_days <= MAXDAYS, "Voting lock can be 4 years max");
        _deposit_for(_msgSender(), 0, _days);
    }

    function withdraw() external override lock {
        LockedBalance storage _locked = locked[_msgSender()];
        require(_locked.amount > 0, "Nothing to withdraw");
        require(now >= _locked.end, "The lock didn't expire");
        uint256 _amount = _locked.amount;
        _locked.end = 0;
        _locked.amount = 0;
        _burn(_msgSender(), mintedForLock[_msgSender()]);
        mintedForLock[_msgSender()] = 0;
        IERC20(lockedToken).safeTransfer(_msgSender(), _amount);

        emit Withdraw(_msgSender(), _amount, now);
    }

    // This will charge PENALTY if lock is not expired yet
    function emergencyWithdraw() external lock {
        LockedBalance storage _locked = locked[_msgSender()];
        require(_locked.amount > 0, "Nothing to withdraw");
        uint256 _amount = _locked.amount;
        if (now < _locked.end) {
            uint256 _fee = _amount.mul(earlyWithdrawFeeRate).div(10000);
            ICappedMintableBurnableERC20(lockedToken).burn(_fee);
            _amount = _amount.sub(_fee);
        }
        _locked.end = 0;
        _locked.amount = 0;
        _burn(_msgSender(), mintedForLock[_msgSender()]);
        mintedForLock[_msgSender()] = 0;

        IERC20(lockedToken).safeTransfer(_msgSender(), _amount);

        emit Withdraw(_msgSender(), _amount, now);
    }

    // This function allows governance to take unsupported tokens out of the contract. This is in an effort to make someone whole, should they seriously mess up.
    // There is no guarantee governance will vote to return these. It also allows for removal of airdropped tokens.
    function governanceRecoverUnsupported(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_token != lockedToken, "core");
        IERC20(_token).safeTransfer(_to, _amount);
    }
}