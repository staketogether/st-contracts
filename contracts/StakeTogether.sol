// SPDX-FileCopyrightText: 2023 Stake Together <info@staketogether.app>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import './SETH.sol';
import './STOracle.sol';
import './interfaces/IDepositContract.sol';

contract StakeTogether is SETH {
  STOracle public immutable stOracle;
  IDepositContract public immutable depositContract;
  bytes public withdrawalCredentials;

  event EtherReceived(address indexed sender, uint amount);

  constructor(address _stOracle, address _depositContract) payable {
    stOracle = STOracle(_stOracle);
    depositContract = IDepositContract(_depositContract);
  }

  receive() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  fallback() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  /*****************
   ** STAKE **
   *****************/

  event DepositPool(
    address indexed account,
    uint256 amount,
    uint256 sharesAmount,
    address delegated,
    address referral
  );

  event WithdrawPool(address indexed account, uint256 amount, uint256 sharesAmount, address delegated);

  event SetWithdrawalCredentials(bytes withdrawalCredentials);
  event SetMinDepositPoolAmount(uint256 amount);

  uint256 public immutable poolSize = 32 ether;
  uint256 public minDepositAmount = 0.000000000000000001 ether;

  function depositPool(
    address _delegated,
    address _referral
  ) external payable nonReentrant whenNotPaused {
    require(_isPool(_delegated), 'NON_POOL_DELEGATE');
    require(msg.value > 0, 'ZERO_VALUE');
    require(msg.value >= minDepositAmount, 'NON_MIN_AMOUNT');

    uint256 sharesAmount = (msg.value * totalShares) / (totalPooledEther() - msg.value);

    emit DepositPool(msg.sender, msg.value, sharesAmount, _delegated, _referral);

    _mintShares(msg.sender, sharesAmount);
    _mintDelegatedShares(msg.sender, _delegated, sharesAmount);
  }

  function withdrawPool(uint256 _amount, address _delegated) external nonReentrant whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(_delegated != address(0), 'MINT_TO_ZERO_ADDR');
    require(_amount <= withdrawalsBalance(), 'NOT_ENOUGH_WITHDRAWALS_BALANCE');
    require(delegationSharesOf(msg.sender, _delegated) > 0, 'NOT_DELEGATION_SHARES');

    uint256 userBalance = balanceOf(msg.sender);

    require(_amount <= userBalance, 'AMOUNT_EXCEEDS_BALANCE');

    uint256 sharesToBurn = (_amount * sharesOf(msg.sender)) / userBalance;

    emit WithdrawPool(msg.sender, _amount, sharesToBurn, _delegated);

    _burnShares(msg.sender, sharesToBurn);
    _burnDelegatedShares(msg.sender, _delegated, sharesToBurn);

    payable(msg.sender).transfer(_amount);
  }

  function setWithdrawalCredentials(bytes memory _withdrawalCredentials) external onlyOwner {
    require(withdrawalCredentials.length == 0, 'WITHDRAWAL_CREDENTIALS_ALREADY_SET');
    withdrawalCredentials = _withdrawalCredentials;
    emit SetWithdrawalCredentials(_withdrawalCredentials);
  }

  function setMinDepositPoolAmount(uint256 _amount) external onlyOwner {
    minDepositAmount = _amount;
    emit SetMinDepositPoolAmount(_amount);
  }

  function poolBalance() public view returns (uint256) {
    return contractBalance() - liquidityBufferBalance - validatorBufferBalance;
  }

  function poolBufferBalance() public view returns (uint256) {
    return poolBalance() + validatorBufferBalance;
  }

  function totalPooledEther() public view override returns (uint256) {
    return
      (contractBalance() + transientBalance + beaconBalance) -
      liquidityBufferBalance -
      validatorBufferBalance;
  }

  function totalEtherSupply() public view returns (uint256) {
    return
      contractBalance() +
      transientBalance +
      beaconBalance +
      liquidityBufferBalance +
      validatorBufferBalance;
  }

  /*****************
   ** LIQUIDITY BUFFER **
   *****************/

  event DepositLiquidityBuffer(address indexed account, uint256 amount);
  event WithdrawLiquidityBuffer(address indexed account, uint256 amount);

  uint256 public liquidityBufferBalance = 0;

  function depositLiquidityBuffer() external payable onlyOwner nonReentrant whenNotPaused {
    require(msg.value > 0, 'ZERO_VALUE');
    liquidityBufferBalance += msg.value;

    emit DepositLiquidityBuffer(msg.sender, msg.value);
  }

  function withdrawLiquidityBuffer(uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(liquidityBufferBalance > _amount, 'AMOUNT_EXCEEDS_BUFFER');

    liquidityBufferBalance -= _amount;

    payable(owner()).transfer(_amount);

    emit WithdrawLiquidityBuffer(msg.sender, _amount);
  }

  function withdrawalsBalance() public view returns (uint256) {
    return poolBalance() + liquidityBufferBalance;
  }

  /*****************
   ** VALIDATOR BUFFER **
   *****************/

  event DepositValidatorBuffer(address indexed account, uint256 amount);
  event WithdrawValidatorBuffer(address indexed account, uint256 amount);

  uint256 public validatorBufferBalance = 0;

  function depositValidatorBuffer() external payable onlyOwner nonReentrant whenNotPaused {
    require(msg.value > 0, 'ZERO_VALUE');
    validatorBufferBalance += msg.value;

    emit DepositValidatorBuffer(msg.sender, msg.value);
  }

  function withdrawValidatorBuffer(uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(validatorBufferBalance > _amount, 'AMOUNT_EXCEEDS_BUFFER');

    validatorBufferBalance -= _amount;

    payable(owner()).transfer(_amount);

    emit WithdrawValidatorBuffer(msg.sender, _amount);
  }

  /*****************
   ** REWARDS **
   *****************/

  event SetTransientBalance(uint256 amount);
  event SetBeaconBalance(uint256 amount);

  function setTransientBalance(uint256 _transientBalance) external override nonReentrant {
    require(msg.sender == address(stOracle), 'ONLY_ST_ORACLE');

    transientBalance = _transientBalance;

    emit SetTransientBalance(_transientBalance);
  }

  function setBeaconBalance(uint256 _beaconBalance) external override nonReentrant {
    require(msg.sender == address(stOracle), 'ONLY_ST_ORACLE');

    uint256 preClBalance = beaconBalance;
    beaconBalance = _beaconBalance;

    _processRewards(preClBalance, _beaconBalance);

    emit SetBeaconBalance(_beaconBalance);
  }

  /*****************
   ** VALIDATOR **
   *****************/

  bytes[] private validators;
  uint256 public totalValidators = 0;

  modifier onlyValidatorModule() {
    require(msg.sender == validatorModuleAddress, 'ONLY_VALIDATOR_MODULE');
    _;
  }

  event CreateValidator(
    address indexed creator,
    uint256 indexed amount,
    bytes publicKey,
    bytes withdrawalCredentials,
    bytes signature,
    bytes32 depositDataRoot
  );

  function createValidator(
    bytes calldata _publicKey,
    bytes calldata _signature,
    bytes32 _depositDataRoot
  ) external onlyValidatorModule nonReentrant {
    require(poolBufferBalance() >= poolSize, 'NOT_ENOUGH_POOL_BALANCE');

    depositContract.deposit{ value: poolSize }(
      _publicKey,
      withdrawalCredentials,
      _signature,
      _depositDataRoot
    );

    validators.push(_publicKey);
    totalValidators++;
    transientBalance += poolSize;

    emit CreateValidator(
      msg.sender,
      poolSize,
      _publicKey,
      withdrawalCredentials,
      _signature,
      _depositDataRoot
    );
  }

  function getValidators() public view returns (bytes[] memory) {
    return validators;
  }

  function isValidator(bytes memory publicKey) public view returns (bool) {
    for (uint256 i = 0; i < validators.length; i++) {
      if (keccak256(validators[i]) == keccak256(publicKey)) {
        return true;
      }
    }
    return false;
  }
}
