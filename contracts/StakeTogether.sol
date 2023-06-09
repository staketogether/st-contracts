// SPDX-FileCopyrightText: 2023 Stake Together Labs <legal@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
import './Shares.sol';

/// @custom:security-contact security@staketogether.app
contract StakeTogether is Shares {
  constructor(
    address _routerContract,
    address _poolsContract,
    address _withdrawalsContract,
    address _loansContract,
    address _validatorsContract
  ) payable {
    routerContract = IRouter(payable(_routerContract));
    poolsContract = IPools(payable(_poolsContract));
    withdrawalsContract = IWithdrawals(payable(_withdrawalsContract));
    loansContract = ILoans(payable(_loansContract));
    validatorsContract = IValidators(payable(_validatorsContract));
  }

  receive() external payable {
    emit ReceiveEther(msg.sender, msg.value);
    _repayLoan();
  }

  fallback() external payable {
    emit FallbackEther(msg.sender, msg.value);
    _repayLoan();
  }

  function pause() public onlyRole(ADMIN_ROLE) {
    _pause();
  }

  function unpause() public onlyRole(ADMIN_ROLE) {
    _unpause();
  }

  /*****************
   ** STAKE **
   *****************/

  uint256 public poolSize = 32 ether;
  uint256 public minDepositAmount = 0.001 ether;
  uint256 public depositLimit = 1000 ether;
  uint256 public walletDepositLimit = 2 ether;
  uint256 public withdrawalLimit = 1000 ether;
  uint256 public blocksPerDay = 6500;
  uint256 public lastResetBlock;
  uint256 public totalDeposited;
  uint256 public totalWithdrawn;

  function _depositBase(address _pool, address _to) internal {
    require(poolsContract.isPool(_pool), 'NON_POOL_DELEGATE');
    require(msg.value > 0, 'ZERO_VALUE');
    require(msg.value >= minDepositAmount, 'NON_MIN_AMOUNT');

    if (walletDepositLimit > 0) {
      require(balanceOf(_to) + msg.value <= walletDepositLimit, 'WALLET_DEPOSIT_LIMIT_REACHED');
    }

    if (msg.value + totalDeposited > depositLimit) {
      emit DepositLimitReached(_to, msg.value);
      revert('DEPOSIT_LIMIT_REACHED');
    }

    uint256 sharesAmount = Math.mulDiv(msg.value, totalShares, totalPooledEther() - msg.value);

    _mintShares(_to, sharesAmount);
    _mintPoolShares(_to, _pool, sharesAmount);

    totalDeposited += msg.value;

    if (block.number > lastResetBlock + blocksPerDay) {
      totalDeposited = msg.value;
      totalWithdrawn = 0;
      lastResetBlock = block.number;
    }

    _repayLoan();
  }

  function depositPool(address _pool, address _referral) external payable nonReentrant whenNotPaused {
    _depositBase(_pool, msg.sender);
    emit DepositPool(msg.sender, msg.value, _pool, _referral);
  }

  function depositDonationPool(
    address _pool,
    address _referral,
    address _to
  ) external payable nonReentrant whenNotPaused {
    _depositBase(_pool, _to);
    emit DepositDonationPool(msg.sender, _to, msg.value, _pool, _referral);
  }

  function _withdrawBase(uint256 _amount, address _pool) internal whenNotPaused {
    require(_amount > 0, 'ZERO_VALUE');
    require(_pool != address(0), 'MINT_TO_ZERO_ADDR');
    require(delegationSharesOf(msg.sender, _pool) > 0, 'NOT_DELEGATION_SHARES');

    if (_amount + totalWithdrawn > withdrawalLimit) {
      emit WithdrawalLimitReached(msg.sender, _amount);
      revert('WITHDRAWAL_LIMIT_REACHED');
    }

    uint256 userBalance = balanceOf(msg.sender);
    require(_amount <= userBalance, 'AMOUNT_EXCEEDS_BALANCE');

    uint256 sharesToBurn = Math.mulDiv(_amount, sharesOf(msg.sender), userBalance);

    _burnShares(msg.sender, sharesToBurn);
    _burnPoolShares(msg.sender, _pool, sharesToBurn);

    totalWithdrawn += _amount;

    if (block.number > lastResetBlock + blocksPerDay) {
      totalDeposited = 0;
      totalWithdrawn = _amount;
      lastResetBlock = block.number;
    }
  }

  function withdrawPool(uint256 _amount, address _pool) external nonReentrant whenNotPaused {
    require(_amount <= poolBalance(), 'NOT_ENOUGH_POOL_BALANCE');
    emit WithdrawPool(msg.sender, _amount, _pool);
    _withdrawBase(_amount, _pool);
    payable(msg.sender).transfer(_amount);
  }

  function withdrawBorrow(uint256 _amount, address _pool) external nonReentrant whenNotPaused {
    require(_amount <= address(loansContract).balance, 'NOT_ENOUGH_BORROW_BALANCE');
    emit WithdrawBorrow(msg.sender, _amount, _pool);
    _withdrawBase(_amount, _pool);
    poolSize += _amount;
    loansContract.borrow(_amount, _pool);
    payable(msg.sender).transfer(_amount);
  }

  function withdrawValidator(uint256 _amount, address _pool) external nonReentrant whenNotPaused {
    // Todo: check borrow conditional rule
    require(_amount <= beaconBalance, 'NOT_ENOUGH_BEACON_BALANCE');
    emit WithdrawValidator(msg.sender, _amount, _pool);
    _withdrawBase(_amount, _pool);
    beaconBalance -= _amount;
    withdrawalsContract.mint(msg.sender, _amount);
  }

  function setDepositLimit(uint256 _newLimit) external onlyRole(ADMIN_ROLE) {
    depositLimit = _newLimit;
    emit SetDepositLimit(_newLimit);
  }

  function setWithdrawalLimit(uint256 _newLimit) external onlyRole(ADMIN_ROLE) {
    withdrawalLimit = _newLimit;
    emit SetWithdrawalLimit(_newLimit);
  }

  function setWalletDepositLimit(uint256 _newLimit) external onlyRole(ADMIN_ROLE) {
    walletDepositLimit = _newLimit;
    emit SetWalletDepositLimit(_newLimit);
  }

  function setBlocksInterval(uint256 _newBlocksInterval) external onlyRole(ADMIN_ROLE) {
    blocksPerDay = _newBlocksInterval;
    emit SetBlocksInterval(_newBlocksInterval);
  }

  function setMinDepositPoolAmount(uint256 _amount) external onlyRole(ADMIN_ROLE) {
    minDepositAmount = _amount;
    emit SetMinDepositPoolAmount(_amount);
  }

  function setPoolSize(uint256 _amount) external onlyRole(ADMIN_ROLE) {
    require(
      _amount >= validatorsContract.validatorSize() + address(loansContract).balance,
      'POOL_SIZE_TOO_LOW'
    );
    poolSize = _amount;
    emit SetPoolSize(_amount);
  }

  function poolBalance() public view returns (uint256) {
    return contractBalance();
  }

  function totalPooledEther() public view override returns (uint256) {
    return contractBalance() + beaconBalance;
  }

  function _repayLoan() internal {
    if (loansContract.balanceOf(address(this)) > 0) {
      uint256 loanAmount = 0;
      if (loansContract.balanceOf(address(this)) >= msg.value) {
        loanAmount = msg.value;
      } else {
        loanAmount = loansContract.balanceOf(address(this));
      }
      loansContract.repayLoan{ value: loanAmount }();
      poolSize -= loanAmount;
    }
  }

  /*****************
   ** VALIDATORS **
   *****************/

  modifier onlyValidatorOracle() {
    require(validatorsContract.isValidatorOracle(msg.sender), 'ONLY_VALIDATOR_ORACLE');
    _;
  }

  bytes public withdrawalCredentials;

  function setWithdrawalCredentials(bytes memory _withdrawalCredentials) external onlyRole(ADMIN_ROLE) {
    require(withdrawalCredentials.length == 0, 'WITHDRAWAL_CREDENTIALS_ALREADY_SET');
    withdrawalCredentials = _withdrawalCredentials;
    emit SetWithdrawalCredentials(_withdrawalCredentials);
  }

  function createValidator(
    bytes calldata _publicKey,
    bytes calldata _signature,
    bytes32 _depositDataRoot
  ) external nonReentrant onlyValidatorOracle {
    validatorsContract.createValidator{ value: validatorsContract.validatorSize() }(
      _publicKey,
      withdrawalCredentials,
      _signature,
      _depositDataRoot
    );

    emit CreateValidator(
      msg.sender,
      validatorsContract.validatorSize(),
      _publicKey,
      withdrawalCredentials,
      _signature,
      _depositDataRoot
    );

    payable(stakeTogetherFeeAddress).transfer(validatorsFee);
  }
}
