pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./IERC20.sol";
import "./ContractWithFlashLoan.sol";
import "./creamfi-helper/CTokenInterfaces.sol";
import "./creamfi-helper/CEtherInterface.sol";
import "./creamfi-helper/ComptrollerInterface.sol";

contract Yielder is ContractWithFlashLoan, Ownable {
    using SafeMath for uint256;
    
    address public constant ETHER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor(address _aaveLPProvider)
        public payable
        ContractWithFlashLoan(_aaveLPProvider)
    {}

    function start(address cTokenAddr, uint256 flashLoanAmount, bool isCEther, bool windYield) public payable onlyOwner {
        address loanToken;
        if (isCEther) {
            loanToken = ETHER;
            // flashLoanAmount = msg.value;
        } else {
            loanToken = CErc20Interface(cTokenAddr).underlying();
        }

        bytes memory params = abi.encode(msg.sender, cTokenAddr, isCEther, windYield);

        initateFlashLoan(address(this), loanToken, flashLoanAmount, params);
    }

    function afterLoanSteps(
        address loanedToken,
        uint256 amount,
        uint256 fees,
        bytes memory params
    ) internal {
        address messageSender;
        address cTokenAddr;
        bool isCEther;
        bool windYield;

        (messageSender, cTokenAddr, isCEther, windYield) = abi.decode(params, (address, address, bool, bool));
        require(owner() == messageSender, "caller is not the owner");

        if (windYield) {
            supplyToCream(cTokenAddr, amount, isCEther);
            cTokenBorrow(cTokenAddr, amount);
        } else {
            repayBorrowedFromCream(cTokenAddr, amount, isCEther);
            cTokenRedeemUnderlying(cTokenAddr, amount);
        }

        if (loanedToken == ETHER) {
            return;
        }

        uint loanRepayAmount = amount.add(fees);
        uint loanedTokenBalOfThis = IERC20(loanedToken).balanceOf(address(this));
        if (loanedTokenBalOfThis < loanRepayAmount) {
            IERC20(loanedToken).transferFrom(messageSender, address(this), loanRepayAmount - loanedTokenBalOfThis);
        }
    }

    function supplyToCream(address cTokenAddr, uint amount, bool isCEther) public payable onlyOwner returns (bool) {
        if (isCEther) {
            CEtherInterface(cTokenAddr).mint.value(amount)();
        } else {
            address underlying = CErc20Interface(cTokenAddr).underlying();
            checkBalThenTransferFrom(underlying, msg.sender, amount);
            checkThenErc20Approve(underlying, cTokenAddr, amount);
            cTokenMint(cTokenAddr, amount);
        }    
        return true;
    }

    function repayBorrowedFromCream(address cTokenAddr, uint amount, bool isCEther) public payable onlyOwner returns (bool) {
        if (isCEther) {
            CEtherInterface(cTokenAddr).repayBorrow.value(amount)();
        } else {
            address underlying = CErc20Interface(cTokenAddr).underlying();
            checkBalThenTransferFrom(underlying, msg.sender, amount);
            checkThenErc20Approve(underlying, cTokenAddr, amount);
            cTokenRepayBorrow(cTokenAddr, amount);
        }    
        return true;
    }

    function withdrawFromCream(address cTokenAddr, uint amount) public onlyOwner returns (bool) {
        return cTokenRedeemUnderlying(cTokenAddr, amount);
    }

    function borrowFromCream(address cTokenAddr, uint amount) public onlyOwner returns (bool) {
        return cTokenBorrow(cTokenAddr, amount);
    }

    function cTokenMint(address cToken, uint mintAmount) internal returns (bool) {
        uint err = CErc20Interface(cToken).mint(mintAmount);
        require(err == 0, "cToken mint failed");
        return true;
    }

    function cTokenRedeemUnderlying(address cToken, uint redeemAmount) internal returns (bool) {
        uint err = CErc20Interface(cToken).redeemUnderlying(redeemAmount);
        require(err == 0, "cToken redeem failed");
        return true;
    }

    function cTokenBorrow(address cToken, uint borrowAmount) internal returns (bool) {
        uint err = CErc20Interface(cToken).borrow(borrowAmount);
        require(err == 0, "cToken borrow failed");
        return true;
    }

    function cTokenRepayBorrow(address cToken, uint repayAmount) internal returns (bool) {
        uint err = CErc20Interface(cToken).repayBorrow(repayAmount);
        require(err == 0, "cToken repay failed");
        return true;
    }

    function claimCream(address comptroller) public onlyOwner {
        ComptrollerInterface(comptroller).claimComp(address(this));
    }

    function claimAndTransferCream(address comptrollerAddr, address receiver) public onlyOwner {

        ComptrollerInterface comptroller = ComptrollerInterface(comptrollerAddr);
        comptroller.claimComp(address(this));

        IERC20 compToken = IERC20(comptroller.getCompAddress());
        uint totalCompBalance = compToken.balanceOf(address(this));

        require(compToken.transfer(receiver, totalCompBalance), "cream transfer failed");
    }

    function claimAndTransferCreamForCToken(address comptrollerAddr, address[] memory cTokens, address receiver) public onlyOwner {
        ComptrollerInterface comptroller = ComptrollerInterface(comptrollerAddr);
        comptroller.claimComp(address(this), cTokens);

        IERC20 compToken = IERC20(comptroller.getCompAddress());
        uint totalCompBalance = compToken.balanceOf(address(this));

        require(compToken.transfer(receiver, totalCompBalance), "cream transfer failed");
    }

    function checkBalThenTransferFrom(address tokenAddress, address user, uint amount) internal returns (bool) {
        uint balOfThis = IERC20(tokenAddress).balanceOf(address(this));
        if (balOfThis < amount) {
            IERC20(tokenAddress).transferFrom(user, address(this), amount);
        }
        return true;
    }

    function checkThenErc20Approve(address tokenAddress, address approveTo, uint amount) internal returns (bool) {
        uint allowance = IERC20(tokenAddress).allowance(address(this), approveTo);
        if (allowance < amount) {
            IERC20(tokenAddress).approve(approveTo, uint(-1));
        }
        return true;
    }

    function transferEth(uint256 amount)
        public
        onlyOwner
        returns (bool success)
    {
        return transferEthInternal(amount);
    }

    function transferEthInternal(uint256 amount)
        internal
        returns (bool success)
    {
        address(uint160(owner())).transfer(amount);
        return true;
    }

    function transferToken(address token, uint256 amount)
        public
        onlyOwner
        returns (bool success)
    {
        return transferTokenInternal(token, amount);
    }

    function transferTokenInternal(address token, uint256 amount)
        internal
        returns (bool success)
    {
        IERC20(token).transfer(owner(), amount);
        return true;
    }

    function tokenBalance(address token) public view returns (uint balance) {
        return IERC20(token).balanceOf(address(this));
    }

    function ethBalance() public view returns (uint balance) {
        return address(this).balance;
    }
}
