// contracts/Presale.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "https://github.com/LayerZero-Labs/solidity-examples/blob/main/contracts/lzApp/NonblockingLzApp.sol";

contract Presale is Ownable, NonblockingLzApp {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    uint16 destChainId;

    // treasury wallet
    address public treasuryWallet;
    address public USDTaddress;
    address public token;

    uint256 public saleEndTime;
    uint256 public numberOfPools;
    uint256 public maxAmount;
    uint256 public minAmount;
    uint8 public tokenDecimals;
    uint256 public salesCount;
    uint256 public totalRaised;

    // Struct to represent a vesting schedule
    struct VestingSchedule {
        uint256 unlockTime;
        uint256 percentageUnlocked;
    }

    // Struct to represent the BuyState
    struct PoolState {
        uint256 nextScheduleId;
        uint256 percentage; //lock percentage
        uint256 price; // price for token
        mapping(uint256 => VestingSchedule) VestingSchedule;
    }

    // Struct to represent the Buyer info
    struct buyerVault {
        mapping(uint256 => uint256) tokenAmount;
        mapping(uint256 => uint256) currencyPaid;
        uint256 txCount;
        mapping(uint256 => bool) ScheduleisClaimed;
    }
    mapping(address => uint256) public contributions;
    mapping(address => bool) public isBuyer;
    mapping(uint256 => PoolState) public BuyPool;
    mapping(address => buyerVault) public buyer;

    event tokenSale(
        address indexed buyer,
        uint256 CurrencyAmount,
        uint256 TokenAmount
    );

    constructor(
        address _tokenAddress,
        uint256 _saleDuration,
        address _USDTaddress,
        address _treasuryWallet,
        address _lzEndpoint,
        uint16 _destChainId
    ) NonblockingLzApp(_lzEndpoint) {
        token = (_tokenAddress);
        saleEndTime = block.timestamp.add(_saleDuration * 1 minutes); // Convert hours to seconds
        tokenDecimals = 18;
        USDTaddress = _USDTaddress;
        treasuryWallet = _treasuryWallet;
        destChainId = _destChainId;
    }

    modifier FullfillRequirement(uint256 _amount) {
        require(_amount >= minAmount, "Amount is below the minimum allowed.");
        require(_amount <= maxAmount, "Amount is above the maximum allowed.");
        require(isActive(), "sale not active!");
        _;
    }

    function buyWithUSDT(uint256 _amount, uint256 _pool)
        external
        FullfillRequirement(_amount)
    {
        address buyerAddress = msg.sender;
        PoolState storage pool = BuyPool[_pool];
        uint256 _tokenAmount = getToken(_amount, _pool);
        // lock percentage
        uint256 tokensTosend = _tokenAmount -
            ((_tokenAmount * pool.percentage) / 100);

        // payment send
        transferCurrency(USDTaddress, buyerAddress, treasuryWallet, _amount);
        // token transfer
        transferCurrency(token, treasuryWallet, buyerAddress, tokensTosend);
        buyer[buyerAddress].tokenAmount[_pool] += _tokenAmount;
        buyer[buyerAddress].currencyPaid[_pool] += _amount;
        buyer[buyerAddress].txCount++;
        contributions[buyerAddress] += getToken(_amount, _pool);
        isBuyer[buyerAddress] = true;
        salesCount++;
        totalRaised += _amount;
        emit tokenSale(buyerAddress, _amount, _tokenAmount);
    }

    function claimTokens(uint256 _pool) external {
        uint256 scheduleCount = BuyPool[_pool].nextScheduleId;
        require(scheduleCount > 0, "No vesting schedules for this pool.");
        address buyerAddress = msg.sender;
        require(isBuyer[buyerAddress], "no buyer");
        buyerVault storage buyerInfo = buyer[buyerAddress];
        uint256 totalTokensClaimed = 0;

        for (uint256 i = 0; i < scheduleCount; i++) {
            VestingSchedule storage schedule = BuyPool[_pool].VestingSchedule[
                i
            ];
            // Check if the schedule is not claimed and the unlock time has passed
            if (
                !buyerInfo.ScheduleisClaimed[i] &&
                block.timestamp >= schedule.unlockTime
            ) {
                uint256 tokensToClaim = (buyerInfo.tokenAmount[_pool] *
                    schedule.percentageUnlocked) / 100;
                require(tokensToClaim > 0, "No tokens to claim.");

                // Mark the schedule as claimed
                buyerInfo.ScheduleisClaimed[i] = true;
                // Transfer the tokens to the buyer
                transferCurrency(
                    token,
                    address(this),
                    msg.sender,
                    tokensToClaim
                );
                totalTokensClaimed = totalTokensClaimed.add(tokensToClaim);
            }
        }
    }

    function addSchemaPrice(uint256 _percentage, uint256 _price)
        external
        onlyOwner
    {
        require(_percentage <= 100, "Percentage must be <= 100");
        PoolState storage pool = BuyPool[numberOfPools];
        pool.price = _price;
        //lock _percentage
        pool.percentage = _percentage;
        numberOfPools++;
    }

    // Function to update the treasuryWallet address
    function setTreasuryWallet(address _newTreasuryWallet) external onlyOwner {
        require(
            _newTreasuryWallet != address(0),
            "Invalid treasury wallet address"
        );
        treasuryWallet = _newTreasuryWallet;
    }

    function minBuyMax(
        uint256 minAmt,
        uint256 maxAmt,
        uint8 _dcml // USDT _dcml
    ) external onlyOwner {
        uint256 min = minAmt * 10**_dcml;
        uint256 max = maxAmt * 10**_dcml;
        minAmount = min;
        maxAmount = max;
    }

    function addVestingSchedule(
        uint256 _pool,
        uint256 _unlockTime,
        uint256 _percentageUnlocked
    ) external onlyOwner {
        require(
            _unlockTime > saleEndTime,
            "Unlock time must be after the sale end."
        );
        // Get the BuyPool and add a new vesting schedule to it
        PoolState storage pool = BuyPool[_pool];
        uint256 scheduleCount = pool.nextScheduleId;
        pool.nextScheduleId += 1;
        uint256 totalpercentageAdded = _percentageUnlocked;
        for (uint256 i = 0; i < scheduleCount; i++) {
            VestingSchedule storage schedule = pool.VestingSchedule[i];
            totalpercentageAdded += schedule.percentageUnlocked;
        }

        require(
            pool.percentage >= totalpercentageAdded,
            "Percentage unlocked exceeds the pool's percentage."
        );
        pool.VestingSchedule[scheduleCount] = VestingSchedule({
            unlockTime: _unlockTime,
            percentageUnlocked: _percentageUnlocked
        });
    }

    function _nonblockingLzReceive(
        uint16,
        bytes memory,
        uint64,
        bytes memory _payload
    ) internal virtual override {
        (address _user, uint256 _amount, uint256 _pool) = abi.decode(
            _payload,
            (address, uint256, uint256)
        );
        PoolState storage pool = BuyPool[_pool];
        uint256 _tokenAmount = getToken(_amount, _pool);
        // lock percentage
        uint256 tokensTosend = _tokenAmount -
            ((_tokenAmount * pool.percentage) / 100);
        // token transfer
        transferCurrency(token, treasuryWallet, _user, tokensTosend);
        buyer[_user].tokenAmount[_pool] += _tokenAmount;
        buyer[_user].currencyPaid[_pool] += _amount;
        buyer[_user].txCount++;
        contributions[_user] += getToken(_amount, _pool);
        isBuyer[_user] = true;
        salesCount++;
        totalRaised += _amount;
        emit tokenSale(_user, _amount, _tokenAmount);
    }

    function trustAddress(address _otherContract) public onlyOwner {
        trustedRemoteLookup[destChainId] = abi.encodePacked(
            _otherContract,
            address(this)
        );
    }

    /// @dev Transfers a given amount of currency.
    function transferCurrency(
        address _currency,
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        if (_amount == 0) {
            return;
        }
        safeTransferERC20(_currency, _from, _to, _amount);
    }

    // @dev Transfer `amount` of ERC20 token from `from` to `to`.
    function safeTransferERC20(
        address _currency,
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        if (_from == _to) {
            return;
        }

        if (_from == address(this)) {
            IERC20(_currency).safeTransfer(_to, _amount);
        } else {
            IERC20(_currency).safeTransferFrom(_from, _to, _amount);
        }
    }

    function getToken(uint256 _amount, uint256 _pool)
        public
        view
        returns (uint256 amount)
    {
        PoolState storage pool = BuyPool[_pool];
        amount = (_amount / pool.price) * 10**tokenDecimals;
    }

    function getUser(uint256 _pool, address _buyerAddress)
        public
        view
        returns (
            uint256 tokenAmount,
            uint256 currencyPaid,
            uint256 txCount
        )
    {
        require(isBuyer[_buyerAddress], "no buyer");
        buyerVault storage buyerInfo = buyer[_buyerAddress];
        tokenAmount = buyerInfo.tokenAmount[_pool];
        currencyPaid = buyerInfo.currencyPaid[_pool];
        txCount = buyerInfo.txCount;
    }

    function getPoolinfo(uint256 _pool)
        public
        view
        returns (
            uint256 percentage,
            uint256 price,
            uint256 nextScheduleId
        )
    {
        PoolState storage pool = BuyPool[_pool];
        percentage = pool.percentage;
        price = pool.price;
        nextScheduleId = pool.nextScheduleId;
    }

    function userToken(uint256 _pool) public view returns (uint256 _token) {
        uint256 scheduleCount = BuyPool[_pool].nextScheduleId;
        require(scheduleCount > 0, "No vesting schedules for this pool.");
        address buyerAddress = msg.sender;
        require(isBuyer[buyerAddress], "no buyer");
        buyerVault storage buyerInfo = buyer[buyerAddress];
        uint256 totalTokensClaimed = 0;

        for (uint256 i = 0; i < scheduleCount; i++) {
            VestingSchedule storage schedule = BuyPool[_pool].VestingSchedule[
                i
            ];
            // Check if the schedule is not claimed and the unlock time has passed
            if (
                !buyerInfo.ScheduleisClaimed[i] &&
                block.timestamp >= schedule.unlockTime
            ) {
                uint256 tokensToClaim = (buyerInfo.tokenAmount[_pool] *
                    schedule.percentageUnlocked) / 100;
                require(tokensToClaim > 0, "No tokens to claim.");
                totalTokensClaimed = totalTokensClaimed.add(tokensToClaim);
            }
        }
        _token = totalTokensClaimed;
    }

    function isActive() public view returns (bool) {
        if (saleEndTime < block.timestamp) {
            return false;
        } else {
            return true;
        }
    }
}
