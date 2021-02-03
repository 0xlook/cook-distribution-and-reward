pragma solidity ^0.6.2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../oracle/IOracle.sol";
import "../oracle/IPriceConsumerV3.sol";
import "hardhat/console.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */
contract CookDistribution is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;


  event AllocationRegistered(
      address indexed beneficiary,
      uint256 amount
  );
  event TokensWithdrawal(address userAddress, uint256 amount);

  struct Allocation {
    uint256 amount;
    uint256 released;
    bool revoked;
  }

  // beneficiary of tokens after they are released
  mapping(address => Allocation) private _beneficiaryAllocations;

  // beneficiary that has been registered
  mapping(address => bool) private _isRegistered;

  // oracle price data (dayNumber => price)
  mapping(uint256 => uint256) private _oraclePriceFeed;

  // all beneficiary address1
  address[] private _allBeneficiary;

  // vesting start time unix
  uint256 private _start;

  // vesting duration in day
  uint256 private _duration;

  // vesting interval
  uint32 private _interval;

  // released percentage triggered by price, should divided by 100
  uint256 private _advancePercentage;

  // last released percentage triggered date in dayNumber
  uint256 private _lastPriceUnlockDay;

  // next step to unlock
  uint32 private _nextPriceUnlockStep;

  IERC20 private _token;

  IOracle private _oracle;
  IPriceConsumerV3 private _priceConsumer;

  bool private _revocable;

  // Date-related constants for sanity-checking dates to reject obvious erroneous inputs
  // SECONDS_PER_DAY = 30 for test only
  uint32 private constant SECONDS_PER_DAY = 86400;  /* 86400 seconds in a day */

  uint256[] private _priceKey;
  uint256[] private _percentageValue;
  mapping(uint256 => uint256) private _pricePercentageMapping;



  constructor(
    IERC20 token_,
    address[] memory beneficiaries_,
    uint256[] memory amounts_,
    uint256 start, // in unix
    uint256 duration, // in day
    uint32 interval, // in day
    bool revocable,
    address oracle_,
    address priceConsumer_
  )
    public
  {
    require(
      beneficiaries_.length == amounts_.length
      ,"Length of input arrays do not match."
    );
    require(duration > 0);
    require(start.add((duration).mul(SECONDS_PER_DAY)) > block.timestamp);


    // init beneficiaries
    for (uint256 i = 0; i < beneficiaries_.length; i++) {
            require(
                beneficiaries_[i] != address(0),
                "Beneficiary cannot be 0 address."
            );

            require(
                amounts_[i] > 0,
                "Cannot allocate zero amount."
            );

            // store all beneficiaries address
            _allBeneficiary.push(beneficiaries_[i]);

            // Add new allocation to beneficiaryAllocations
            _beneficiaryAllocations[beneficiaries_[i]] = Allocation(
                amounts_[i],
                0,
                false
            );

            _isRegistered[beneficiaries_[i]] = true;

            emit AllocationRegistered(beneficiaries_[i], amounts_[i]);
        }

    _token = token_;
    _revocable = revocable;
    _duration = duration;
    _start = start;
    _interval = interval;
    _advancePercentage = 0;
    _oracle = IOracle(oracle_);
    _priceConsumer = IPriceConsumerV3(priceConsumer_);
    _lastPriceUnlockDay = 0;
    _nextPriceUnlockStep = 0;

    // init price percentage

    _priceKey = [500000,800000,1100000,1400000,1700000,2000000,2300000,2600000,2900000,3200000,3500000,3800000,4100000,4400000,4700000,5000000,5300000,5600000,5900000,6200000,6500000];
    _percentageValue = [1,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];

    for (uint256 i = 0; i < _priceKey.length; i++) {
      _pricePercentageMapping[_priceKey[i]] = _percentageValue[i];
    }
  }

  /**
    * add adddress with allocation
    */
  function addAddressWithAllocation(address beneficiaryAddress, uint256 amount) public onlyOwner {
      _isRegistered[beneficiaryAddress] = true;
      _beneficiaryAllocations[beneficiaryAddress] = Allocation(
          amount,
          0,
          false
      );
  }

  /**
    * add adddress with allocation
    */
  function updatePricePercentage(uint256[] memory priceKey_, uint256[] memory percentageValue_) public onlyOwner {
    _priceKey = priceKey_;
    _percentageValue = percentageValue_;

    for (uint256 i = 0; i < _priceKey.length; i++) {
      _pricePercentageMapping[_priceKey[i]] = _percentageValue[i];
    }

  }


  /**
   * @return the start time of the token vesting. in unix
   */
  function start() public view returns(uint256) {
    return _start;
  }

  /**
   * @return the duration of the token vesting. in day
   */
  function duration() public view returns(uint256) {
    return _duration;
  }

  /**
   * @return true if the vesting is revocable.
   */
  function revocable() public view returns(bool) {
    return _revocable;
  }

  /**
   * @return the registerd state.
   */
  function getRegisteredStatus(address userAddress) public view returns(bool) {
    return _isRegistered[userAddress];
  }

  function getUserVestingAmount(address userAddress) public view returns (uint256 amount) {

      return _beneficiaryAllocations[userAddress].amount;
  }

  /**
   * return total vested cook amount
   */
  function getTotalAvailable() public onlyOwner view returns (uint256 amount) {
    uint256 totalAvailable = 0;

    for (uint256 i = 0; i < _allBeneficiary.length; ++i) {
      totalAvailable += getUserAvailableAmount(_allBeneficiary[i], today());
    }


    return totalAvailable;
  }


  /**
     * @dev returns the day number of the current day, in days since the UNIX epoch.
     */
    function today() virtual public view returns (uint256 dayNumber) {
        return uint256(block.timestamp / SECONDS_PER_DAY);
    }

    function startDay() public view returns (uint256 dayNumber) {
        return uint256(_start / SECONDS_PER_DAY);
    }

    function _effectiveDay(uint256 onDayOrToday) internal view returns (uint256 dayNumber) {
        return onDayOrToday == 0 ? today() : onDayOrToday;
    }

    function _getVestedAmount(address userAddress, uint256 onDayOrToday) internal view returns (uint256 amountNotVested) {
        uint256 onDay = _effectiveDay(onDayOrToday); // day

        // If after end of vesting, then the vested amount is total amount.
        if (onDay >= (startDay() +_duration)) {
          return _beneficiaryAllocations[userAddress].amount;
        }
        // If it's before the vesting then the vested amount is zero.
        else if (onDay <= startDay())
        {
            // All are vested (none are not vested)
            return uint256(0);
        }
        // Otherwise a fractional amount is vested.
        else
        {
            // Compute the exact number of days vested.
            uint256 daysVested = onDay - startDay();
            // Adjust result rounding down to take into consideration the interval.
            uint256 effectiveDaysVested = (daysVested / _interval) * _interval;

            // Compute the fraction vested from schedule using 224.32 fixed point math for date range ratio.
            // Note: This is safe in 256-bit math because max value of X billion tokens = X*10^27 wei, and
            // typical token amounts can fit into 90 bits. Scaling using a 32 bits value results in only 125
            // bits before reducing back to 90 bits by dividing. There is plenty of room left, even for token
            // amounts many orders of magnitude greater than mere billions.

            uint256 vested = 0;

            if(_beneficiaryAllocations[userAddress].amount.mul(effectiveDaysVested).div(_duration) > _beneficiaryAllocations[userAddress].amount.mul(_advancePercentage).div(100)){
              // no price based percentage > date based percentage
              vested = _beneficiaryAllocations[userAddress].amount.mul(effectiveDaysVested).div(_duration);
            } else {
              // price based percentage > date based percentage
              vested = _beneficiaryAllocations[userAddress].amount.mul(_advancePercentage).div(100);
            }

            return vested;
        }
    }


    function getUserAvailableAmount(address userAddress, uint256 onDayOrToday) public view returns (uint256 amountAvailable) {
        uint256 onDay = _effectiveDay(onDayOrToday);
        uint256 avalible = _getVestedAmount(userAddress,onDay).sub(_beneficiaryAllocations[userAddress].released);
        return avalible;
    }





  /**
    withdraw function
   */
  function withdraw(uint256 withdrawAmount) public {

    address userAddress = msg.sender;

    require(
        _isRegistered[userAddress] == true,
        "You have to be a registered address in order to release tokens."
    );


    require(getUserAvailableAmount(userAddress,today()) >= withdrawAmount,"insufficient avalible balance");

    _beneficiaryAllocations[userAddress].released = _beneficiaryAllocations[userAddress].released.add(withdrawAmount);

    _token.safeTransfer(userAddress, withdrawAmount);

    emit TokensWithdrawal(userAddress, withdrawAmount);
  }

  function getLatestSevenSMA() public onlyOwner returns(uint256 priceValue) {
    // 7 day sma
    uint256 priceSum = uint256(0);
    uint256 priceCount = uint256(0);
    for (uint32 i = 0; i < 7; ++i) {
      if( _oraclePriceFeed[today()-i] != uint256(0)) {
        priceSum = priceSum + _oraclePriceFeed[today()-i];
        priceCount += 1;
      }
    }

    uint256 sevenSMA = 0;
    if(priceCount == uint256(7)){
      sevenSMA = priceSum.div(priceCount);
    }
    return sevenSMA;

  }

  /**
   * update price feed and update price-based unlock percentage
   */
  function updatePriceFeed() public onlyOwner {

    // oracle capture -> 900000000000000000 -> 1 cook = 0.9 ETH
    uint256 cookPrice = _oracle.update();

    // ETH/USD capture -> 127164849196 -> 1ETH = 1271.64USD
    uint256 ethPrice = uint256(_priceConsumer.getLatestPrice());

    uint256 price = cookPrice.mul(ethPrice).div(10**18);

    // update price to _oraclePriceFeed
    _oraclePriceFeed[today()] = price;

    if(today() >= _lastPriceUnlockDay.add(7)){
      // 7 day sma
      uint256 sevenSMA = getLatestSevenSMA();
      uint256 priceRef = 0;

      for (uint32 i = 0; i < _priceKey.length; ++i) {
        if(sevenSMA >= _priceKey[i]){
          priceRef = _pricePercentageMapping[_priceKey[i]];
        }
      }

      // no lower action if the price drop after price-based unlock
      if(priceRef > _advancePercentage){
        // guard _nextPriceUnlockStep exceed
        if(_nextPriceUnlockStep >= _percentageValue.length){
          _nextPriceUnlockStep = uint32(_percentageValue.length - 1);
        }

        // update _advancePercentage to nextStep percentage
        _advancePercentage = _pricePercentageMapping[_priceKey[_nextPriceUnlockStep]];

        // update nextStep value
        _nextPriceUnlockStep = _nextPriceUnlockStep + 1;

        // update lastUnlcokDay
        _lastPriceUnlockDay = today();

      }
    }

  }

  function _getPricePercentage(uint256 priceKey) internal view returns (uint256 percentageValue) {
    return _pricePercentageMapping[priceKey];
  }
}
