// SPDX-FileCopyrightText: 2023 Stake Together Labs <legal@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './interfaces/IDepositContract.sol';
import './interfaces/IRouter.sol';
import './interfaces/IPools.sol';
import './interfaces/IWithdrawals.sol';
import './interfaces/ILoans.sol';
import './interfaces/IStakeTogether.sol';
import './interfaces/IValidators.sol';

/// @custom:security-contact security@staketogether.app
abstract contract Shares is IStakeTogether, AccessControl, Pausable, ReentrancyGuard, ERC20, ERC20Permit {
  bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');

  IRouter public routerContract;
  IPools public poolsContract;
  IWithdrawals public withdrawalsContract;
  ILoans public loansContract;
  IValidators public validatorsContract;

  constructor() ERC20('ST Staked Ether', 'SETH') ERC20Permit('ST Staked Ether') {
    _bootstrap();

    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(ADMIN_ROLE, msg.sender);
  }

  modifier onlyRouter() {
    require(msg.sender == address(routerContract), 'ONLY_DISTRIBUTOR_CONTRACT');
    _;
  }

  modifier onlyPool() {
    require(msg.sender == address(poolsContract), 'ONLY_POOL_CONTRACT');
    _;
  }

  /************
   ** SHARES **
   ************/

  mapping(address => uint256) private shares;
  uint256 public totalShares = 0;
  mapping(address => mapping(address => uint256)) private allowances;

  function _bootstrap() internal {
    address stakeTogether = address(this);
    uint256 balance = stakeTogether.balance;

    require(balance > 0, 'NON_ZERO_VALUE');

    emit Bootstrap(msg.sender, balance);

    _mintShares(stakeTogether, balance);
    _mintPoolShares(stakeTogether, stakeTogether, balance);

    setStakeTogetherFeeAddress(msg.sender);
    setOperatorFeeAddress(msg.sender);
  }

  function contractBalance() public view returns (uint256) {
    return address(this).balance;
  }

  function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
    return totalPooledEther();
  }

  function balanceOf(address _account) public view override(ERC20, IERC20) returns (uint256) {
    return pooledEthByShares(netSharesOf(_account));
  }

  function sharesOf(address _account) public view returns (uint256) {
    return shares[_account];
  }

  function netSharesOf(address _account) public view returns (uint256) {
    return shares[_account] - lockedShares[_account];
  }

  function sharesByPooledEth(uint256 _ethAmount) public view returns (uint256) {
    return Math.mulDiv(_ethAmount, totalShares, totalPooledEther());
  }

  function pooledEthByShares(uint256 _sharesAmount) public view returns (uint256) {
    return Math.mulDiv(_sharesAmount, totalPooledEther(), totalShares);
  }

  function transfer(address _to, uint256 _amount) public override(ERC20, IERC20) returns (bool) {
    _transfer(msg.sender, _to, _amount);
    return true;
  }

  function transferFrom(
    address _from,
    address _to,
    uint256 _amount
  ) public override(ERC20, IERC20) returns (bool) {
    _spendAllowance(_from, msg.sender, _amount);
    _transfer(_from, _to, _amount);

    return true;
  }

  function transferShares(address _to, uint256 _sharesAmount) public returns (uint256) {
    _transferShares(msg.sender, _to, _sharesAmount);
    uint256 tokensAmount = pooledEthByShares(_sharesAmount);
    return tokensAmount;
  }

  function transferSharesFrom(
    address _from,
    address _to,
    uint256 _sharesAmount
  ) external returns (uint256) {
    uint256 tokensAmount = pooledEthByShares(_sharesAmount);
    _spendAllowance(_from, msg.sender, tokensAmount);
    _transferShares(_from, _to, _sharesAmount);
    return tokensAmount;
  }

  function allowance(
    address _account,
    address _spender
  ) public view override(ERC20, IStakeTogether) returns (uint256) {
    return allowances[_account][_spender];
  }

  function approve(
    address _spender,
    uint256 _amount
  ) public override(ERC20, IStakeTogether) returns (bool) {
    _approve(msg.sender, _spender, _amount);
    return true;
  }

  function increaseAllowance(
    address _spender,
    uint256 _addedValue
  ) public override(ERC20, IStakeTogether) returns (bool) {
    _approve(msg.sender, _spender, allowances[msg.sender][_spender] + _addedValue);
    return true;
  }

  function decreaseAllowance(
    address _spender,
    uint256 _subtractedValue
  ) public override(ERC20, IStakeTogether) returns (bool) {
    uint256 currentAllowance = allowances[msg.sender][_spender];
    require(currentAllowance >= _subtractedValue, 'ALLOWANCE_BELOW_ZERO');
    _approve(msg.sender, _spender, currentAllowance - _subtractedValue);
    return true;
  }

  function totalPooledEther() public view virtual returns (uint256);

  function _approve(address _account, address _spender, uint256 _amount) internal override {
    require(_account != address(0), 'APPROVE_FROM_ZERO_ADDR');
    require(_spender != address(0), 'APPROVE_TO_ZERO_ADDR');

    allowances[_account][_spender] = _amount;
    emit Approval(_account, _spender, _amount);
  }

  function _mintShares(address _to, uint256 _sharesAmount) internal whenNotPaused {
    require(_to != address(0), 'MINT_TO_ZERO_ADDR');

    shares[_to] = shares[_to] + _sharesAmount;
    totalShares += _sharesAmount;

    emit MintShares(_to, _sharesAmount);
  }

  function _burnShares(address _account, uint256 _sharesAmount) internal whenNotPaused {
    require(_account != address(0), 'BURN_FROM_ZERO_ADDR');
    require(_sharesAmount <= netSharesOf(_account), 'BALANCE_EXCEEDED');

    shares[_account] = shares[_account] - _sharesAmount;
    totalShares -= _sharesAmount;

    emit BurnShares(_account, _sharesAmount);
  }

  function _transfer(address _from, address _to, uint256 _amount) internal override {
    uint256 _sharesToTransfer = sharesByPooledEth(_amount);
    _transferShares(_from, _to, _sharesToTransfer);
    _transferDelegationShares(_from, _to, _sharesToTransfer);
    emit Transfer(_from, _to, _amount);
  }

  function _transferShares(address _from, address _to, uint256 _sharesAmount) internal whenNotPaused {
    require(_from != address(0), 'TRANSFER_FROM_ZERO_ADDR');
    require(_to != address(0), 'TRANSFER_TO_ZERO_ADDR');
    require(_to != address(this), 'TRANSFER_TO_ST_CONTRACT');
    require(_sharesAmount <= netSharesOf(_from), 'BALANCE_EXCEEDED');

    shares[_from] = shares[_from] - _sharesAmount;
    shares[_to] = shares[_to] + _sharesAmount;

    emit TransferShares(_from, _to, _sharesAmount);
  }

  function _spendAllowance(address _account, address _spender, uint256 _amount) internal override {
    uint256 currentAllowance = allowances[_account][_spender];
    if (currentAllowance != ~uint256(0)) {
      require(currentAllowance >= _amount, 'ALLOWANCE_EXCEEDED');
      _approve(_account, _spender, currentAllowance - _amount);
    }
  }

  /*****************
   ** LOCK SHARES **
   *****************/

  modifier onlyLoans() {
    require(msg.sender == address(loansContract), 'ONLY_LOAN_CONTRACT');
    _;
  }

  mapping(address => Lock[]) public locked;
  mapping(address => uint256) public lockedShares;
  uint256 public totalLockedShares;
  uint256 public maxActiveLocks = 10;

  function setMaxActiveLocks(uint256 _amount) external onlyRole(ADMIN_ROLE) {
    maxActiveLocks = _amount;
    emit SetMaxActiveLocks(_amount);
  }

  function lockedSharesOf(address _account) public view returns (uint256) {
    return lockedShares[_account];
  }

  function lockShares(
    uint256 _sharesAmount,
    uint256 _blocks
  ) external onlyLoans nonReentrant whenNotPaused {
    require(locked[msg.sender].length < maxActiveLocks, 'TOO_MANY_LOCKS');
    require(_sharesAmount <= shares[msg.sender], 'BALANCE_EXCEEDED');
    require(_blocks > 0, 'BLOCKS_MUST_BE_GREATER_THAN_ZERO');

    shares[msg.sender] -= _sharesAmount;
    lockedShares[msg.sender] += _sharesAmount;
    totalLockedShares += _sharesAmount;

    Lock memory newLock = Lock(_sharesAmount, block.number + _blocks);
    locked[msg.sender].push(newLock);

    emit SharesLocked(msg.sender, _sharesAmount, newLock.unlockBlock);
  }

  function unlockShares() external nonReentrant whenNotPaused {
    Lock[] storage locks = locked[msg.sender];
    require(locks.length > 0, 'NO_LOCKS_FOUND');

    for (uint256 i = 0; i < locks.length; i++) {
      if (locks[i].unlockBlock <= block.number) {
        uint256 amount = locks[i].amount;
        shares[msg.sender] += amount;
        lockedShares[msg.sender] -= amount;
        totalLockedShares -= amount;

        _removeLock(msg.sender, i);
        i--;

        emit SharesUnlocked(msg.sender, amount);
      }
    }
  }

  function unlockSpecificLock(uint256 _index) external nonReentrant whenNotPaused {
    Lock[] storage locks = locked[msg.sender];
    require(_index < locks.length, 'INVALID_INDEX');
    require(locks[_index].unlockBlock <= block.number, 'LOCK_NOT_EXPIRED');

    uint256 amount = locks[_index].amount;
    shares[msg.sender] += amount;
    lockedShares[msg.sender] -= amount;
    totalLockedShares -= amount;

    _removeLock(msg.sender, _index);

    emit SharesUnlocked(msg.sender, amount);
  }

  function _removeLock(address _account, uint256 _index) internal {
    Lock[] storage locks = locked[_account];
    require(_index < locks.length, 'INVALID_INDEX');

    locks[_index] = locks[locks.length - 1];
    locks.pop();
  }

  /*****************
   ** POOLS SHARES **
   *****************/

  mapping(address => uint256) private poolShares;
  uint256 public totalPoolShares = 0;
  mapping(address => mapping(address => uint256)) private delegationsShares;
  mapping(address => address[]) private delegates;
  mapping(address => mapping(address => bool)) private isDelegate;
  uint256 public maxDelegations = 64; // Todo: verify merkle tree

  function poolSharesOf(address _account) public view returns (uint256) {
    return poolShares[_account];
  }

  function delegationSharesOf(address _account, address _pool) public view returns (uint256) {
    return delegationsShares[_account][_pool];
  }

  function transferPoolShares(
    address _fromPool,
    address _toPool,
    uint256 _sharesAmount
  ) external nonReentrant whenNotPaused {
    _transferPoolShares(msg.sender, _fromPool, _toPool, _sharesAmount);
  }

  function _transferPoolShares(
    address _account,
    address _fromPool,
    address _toPool,
    uint256 _sharesAmount
  ) internal {
    require(_account != address(0), 'ZERO_ADDR');
    require(_fromPool != address(0), 'ZERO_ADDR');
    require(_toPool != address(0), 'ZERO_ADDR');
    require(_toPool != address(this), 'ST_ADDR');
    require(poolsContract.isPool(_toPool), 'ONLY_CAN_TRANSFER_TO_POOL');

    require(_sharesAmount <= delegationsShares[_account][_fromPool], 'BALANCE_EXCEEDED');

    poolShares[_fromPool] -= _sharesAmount;
    delegationsShares[_account][_fromPool] -= _sharesAmount;

    poolShares[_toPool] += _sharesAmount;
    delegationsShares[_account][_toPool] += _sharesAmount;

    emit TransferPoolShares(_account, _fromPool, _toPool, _sharesAmount);
  }

  function _mintPoolShares(address _to, address _pool, uint256 _sharesAmount) internal whenNotPaused {
    require(_to != address(0), 'MINT_TO_ZERO_ADDR');
    require(poolsContract.isPool(_pool), 'ONLY_CAN_DELEGATE_TO_POOL');
    require(delegates[_to].length < maxDelegations, 'MAX_DELEGATIONS_REACHED');
    require(_sharesAmount > 0, 'MINT_INVALID_AMOUNT');

    poolShares[_pool] += _sharesAmount;
    delegationsShares[_to][_pool] += _sharesAmount;
    totalPoolShares += _sharesAmount;

    if (!isDelegate[_to][_pool]) {
      delegates[_to].push(_pool);
      isDelegate[_to][_pool] = true;
    }

    emit MintPoolShares(_to, _pool, _sharesAmount);
  }

  function _burnPoolShares(address _to, address _pool, uint256 _sharesAmount) internal whenNotPaused {
    require(_to != address(0), 'BURN_to_ZERO_ADDR');
    require(poolsContract.isPool(_pool), 'ONLY_CAN_BURN_to_POOL');
    require(delegationsShares[_to][_pool] >= _sharesAmount, 'BURN_INVALID_AMOUNT');
    require(_sharesAmount > 0, 'BURN_INVALID_AMOUNT');

    poolShares[_pool] -= _sharesAmount;
    delegationsShares[_to][_pool] -= _sharesAmount;
    totalPoolShares -= _sharesAmount;

    if (delegationsShares[_to][_pool] == 0) {
      isDelegate[_to][_pool] = false;

      for (uint i = 0; i < delegates[_to].length; i++) {
        if (delegates[_to][i] == _pool) {
          delegates[_to][i] = delegates[_to][delegates[_to].length - 1];
          delegates[_to].pop();
          break;
        }
      }
    }

    emit BurnPoolShares(_to, _pool, _sharesAmount);
  }

  function _transferDelegationShares(
    address _from,
    address _to,
    uint256 _sharesToTransfer
  ) internal whenNotPaused {
    require(_sharesToTransfer <= sharesOf(_from), 'TRANSFER_EXCEEDS_BALANCE');

    for (uint256 i = 0; i < delegates[_from].length; i++) {
      address pool = delegates[_from][i];
      uint256 delegationSharesToTransfer = Math.mulDiv(
        delegationSharesOf(_from, pool),
        _sharesToTransfer,
        sharesOf(_from)
      );

      delegationsShares[_from][pool] -= delegationSharesToTransfer;

      if (!isDelegate[_to][pool]) {
        require(delegates[_to].length < maxDelegations, 'MAX_DELEGATIONS_REACHED');
        delegates[_to].push(pool);
        isDelegate[_to][pool] = true;
      }

      delegationsShares[_to][pool] += delegationSharesToTransfer;

      if (delegationSharesOf(_from, pool) == 0) {
        isDelegate[_from][pool] = false;
      }

      emit TransferDelegationShares(_from, _to, pool, delegationSharesToTransfer);
    }
  }

  /*****************
   ** ADDRESSES **
   *****************/

  address public poolsFeeAddress;
  address public operatorsFeeAddress;
  address public stakeTogetherFeeAddress;

  function setPoolsFeeAddress(address _to) public onlyRole(ADMIN_ROLE) {
    require(_to != address(0), 'NON_ZERO_ADDR');
    poolsFeeAddress = _to;
    emit SetPoolsFeeAddress(_to);
  }

  function setOperatorFeeAddress(address _to) public onlyRole(ADMIN_ROLE) {
    require(_to != address(0), 'NON_ZERO_ADDR');
    operatorsFeeAddress = _to;
    emit SetOperatorsFeeAddress(_to);
  }

  function setStakeTogetherFeeAddress(address _to) public onlyRole(ADMIN_ROLE) {
    require(_to != address(0), 'NON_ZERO_ADDR');
    stakeTogetherFeeAddress = _to;
    emit SetStakeTogetherFeeAddress(_to);
  }

  /*****************
   ** FEES **
   *****************/

  uint256 public stakeTogetherFee = 0.03 ether;
  uint256 public operatorsFee = 0.03 ether;
  uint256 public poolsFee = 0.03 ether;

  uint256 public validatorsFee = 0.001 ether;

  uint256 public addPoolFee = 1 ether;

  uint256 public entryFee = 0.003 ether;

  function setStakeTogetherFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    stakeTogetherFee = _fee;
    emit SetStakeTogetherFee(_fee);
  }

  function setPoolsFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    poolsFee = _fee;
    emit SetPoolsFee(_fee);
  }

  function setOperatorFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    operatorsFee = _fee;
    emit SetOperatorsFee(_fee);
  }

  function setValidatorFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    validatorsFee = _fee;
    emit SetValidatorsFee(_fee);
  }

  function setAddPoolFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    addPoolFee = _fee;
    emit SetAddPoolFee(_fee);
  }

  function setEntryFee(uint256 _fee) external onlyRole(ADMIN_ROLE) {
    entryFee = _fee;
    emit SetEntryFee(_fee);
  }

  /*****************
   ** REWARDS **
   *****************/

  uint256 public beaconBalance = 0;

  // Todo: Implement function set beacon balance

  modifier onlyValidators() {
    require(msg.sender == address(validatorsContract), 'ONLY_VALIDATORS_CONTRACT');
    _;
  }

  function setBeaconBalance(uint256 _amount) external onlyValidators {
    beaconBalance = _amount;
    emit SetBeaconBalance(_amount);
  }

  function mintRewards(
    uint256 _epoch,
    address _rewardAddress,
    uint256 _sharesAmount
  ) external payable nonReentrant onlyRouter {
    _mintShares(_rewardAddress, _sharesAmount);
    _mintPoolShares(_rewardAddress, _rewardAddress, _sharesAmount); // Todo: verify pools shares not claimed

    if (_rewardAddress == stakeTogetherFeeAddress) {
      emit MintRewards(_epoch, _rewardAddress, _sharesAmount, RewardType.StakeTogether);
    } else if (_rewardAddress == operatorsFeeAddress) {
      emit MintRewards(_epoch, _rewardAddress, _sharesAmount, RewardType.Operator);
    } else {
      emit MintRewards(_epoch, _rewardAddress, _sharesAmount, RewardType.Pools);
    }
  }

  function mintPenalty(uint256 _blockNumber, uint256 _lossAmount) external nonReentrant onlyRouter {
    beaconBalance -= _lossAmount;
    require(totalPooledEther() - _lossAmount > 0, 'NEGATIVE_TOTAL_POOLED_ETHER_BALANCE');
    emit MintPenalty(_blockNumber, _lossAmount);
  }

  function refundPool(uint256 _epoch) external payable nonReentrant onlyRouter {
    emit RefundPool(_epoch, msg.value);
  }

  function depositPool() external payable nonReentrant {
    emit DepositPool(msg.value);
  }

  function claimPoolRewards(
    address _account,
    uint256 _sharesAmount
  ) external nonReentrant whenNotPaused onlyPool {
    _transferShares(_account, address(this), _sharesAmount);
    _transferPoolShares(address(poolsContract), address(poolsContract), _account, _sharesAmount);
    emit ClaimPoolRewards(_account, _sharesAmount);
  }
}
