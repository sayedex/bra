// contracts/Presale.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    uint256 public maxAmount;
    uint256 public minAmount;
    uint8 public tokenDecimals;



    event requestsend(
        address indexed buyer,
        uint256 CurrencyAmount
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
        emit requestsend(_user, _amount);
    }
  

    function BuytokenInBSC(uint256 _amount, uint256 _pool)
        public
        payable
        FullfillRequirement(_amount)
    {
        // for BUSD
        uint256 amount = (_amount / 10**6) * 10**18;
        transferCurrency(USDTaddress, msg.sender, treasuryWallet, amount);
        //send the transation
        bytes memory payload = abi.encode(msg.sender, _amount, _pool);
        _lzSend(
            destChainId,
            payload,
            payable(msg.sender),
            address(0x0),
            bytes(""),
            msg.value
        );
         emit requestsend(msg.sender, _amount);
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


    function isActive() public view returns (bool) {
        if (saleEndTime < block.timestamp) {
            return false;
        } else {
            return true;
        }
    }
}

