// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./@openzeppelin/contracts/access/Ownable.sol";
import "./@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./@uniswap/interfaces/IUniswapV2Router02.sol";
import "./@uniswap/interfaces/IUniswapV2Factory.sol";
import "./@uniswap/interfaces/IUniswapV2Pair.sol";
import "./@utils/math/SafeMathInt.sol";
import "./@utils/math/SafeMathUint.sol";

contract ShiwaToken is ERC20, Ownable {
    using SafeMathUint for uint256;
    using SafeMathInt for int256;
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExemptedFromHeld;
    mapping(address => bool) public isExcludedFromReward;
    address[] public ExclusionRewardList;
    uint256 constant private MAGNITUDE = 2**165;
    mapping(address => uint256) private magnifiedDividendPerShareMap; //token=>amount
    mapping(address => mapping(address => int256)) private magnifiedDividendCorrectionsMap; //token=>user=>amount
    mapping(address => mapping(address => uint256)) private withdrawnDividendsMap; //token=>user=>amount
    mapping(address => bool) public pairMap;
    EnumerableSet.AddressSet private _dividendTokenSet; //div-addressSet

    uint256 public currentTXCount;
    uint256 public SWAP_MIN_TOKEN = 1000000000000000000000;
    uint256 public SWAP_MIN_TX = 20;
    bool public SHOULD_SWAP = true;
    bool public TAKE_FEE = true;
    uint256 public MAX_RATIO = 500; //5% of total supply() at the time of tx
    uint256 public BUY_TX_FEE = 700;
    uint256 public SELL_TX_FEE = 700;
    uint256 public USUAL_TX_FEE = 700;
    uint256 public MARK_FEE = 9000;
    uint256 public DEV_FEE = 100;
    uint256 public LPR_FEE = 1000;
    uint256 public swapTokensAmount; //total tokens to be swapped
    address public currentRewardToken;
    uint256 private constant maxTokenLen = 5; //max dividend tokens
    //Fee in basis points (BP) 1%=100 points, min 0.1% = 10bp
    //amount.mul(fee).div(10000::10k) := fee
    //amount.sub(fee) = rest
    uint256 private constant BASE_DIVIDER = 10000; // constant 100%
    uint256 private constant MIN_DIVIDER = 100; // constant min 1%
    address payable private constant BURN_WALLET = payable(0x000000000000000000000000000000000000dEaD);
    address payable public MARK_WALLET = payable(0x9D38F6581Cb7635CD5bf031Af1E1635b42db74fe);
    address payable public DEV_WALLET = payable(0x9D38F6581Cb7635CD5bf031Af1E1635b42db74fe);

    IUniswapV2Router02 public UniswapV2Router;
    address public uniswapV2Pair;

    event DividendsDistributed(
        address token,
        uint256 weiAmount
    );
    event DividendWithdrawn(
        address to,
        address token,
        uint256 weiAmount
    );

    receive() external payable {}

    constructor(address router) ERC20("ShiwaToken", "SHIWA") {
        uint256 amount = (1000000000000000 * 10 ** decimals());
        _mint(_msgSender(), amount);
        UniswapV2Router = IUniswapV2Router02(router);
        _initPairCreationHook();
        isExcludedFromFees[_msgSender()] = true;
        isExcludedFromFees[MARK_WALLET] = true;
        isExcludedFromFees[DEV_WALLET] = true;
        isExcludedFromFees[BURN_WALLET] = true;
        isExcludedFromFees[address(0)] = true;
        isExcludedFromFees[address(this)] = true;
        isExemptedFromHeld[router] = true;
        isExcludedFromReward[_msgSender()] = true;
        ExclusionRewardList.push(_msgSender());
        pairMap[router] = true;
        _dividendTokenSet.add(address(this));
        currentRewardToken = address(this);
    }

    /**
     * liquid guard for potential <SWC-107>.
     */
    bool public isNowLiquid;

    /**
     * @dev get total token supply - excluded
     * @notice extension of the following implementations for Dividends:
     * https://github.com/ethereum/EIPs/issues/1726
     * https://github.com/Roger-Wu/erc1726-dividend-paying-token/blob/master/contracts
     * https://github.com/Alexander-Herranz/ERC20DividendPayingToken
     * deduct the supply from excluded reward since those will be distributed.
     */
    function getReducedSupply() public view returns(uint256) {
        uint256 deductSupply = 0;
        uint256 eLen = ExclusionRewardList.length;
        if (eLen > 0) {
            for (uint256 i = 0; i < eLen; i++) {
                deductSupply += balanceOf(ExclusionRewardList[i]);
            }
        }
        deductSupply += balanceOf(BURN_WALLET) + 
                        balanceOf(address(0)) + 
                        balanceOf(address(this)) + 
                        balanceOf(address(UniswapV2Router));
        uint256 supply = totalSupply();
        uint256 netSupply = (supply - deductSupply) == 0 ? (1000 * 10 ** decimals()) : (supply - deductSupply);
        return netSupply;
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public override(ERC20) returns (bool) {
        address owner = _msgSender();
        _preTransferHook(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20) returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _preTransferHook(from, to, amount);
        return true;
    }

    /**
     * @dev handles token liquidity and distributions
     * - swap fees to ETH
     * - provide liquidity
     * - distribute tokens
     * - doesn't revert on failure <SWC-113>.
     */
    function liquidSwapProvider(uint256 tokens) private returns (bool) {
        if (isNowLiquid == false) {
            isNowLiquid = true;
            uint256 prevTokens = balanceOf(address(this));
            uint256 lprTokens = (tokens * LPR_FEE) / BASE_DIVIDER;
            uint256 tokensToSwap = tokens - lprTokens;

            if (currentRewardToken == address(this)) { //this_token
                //distribute rewards
                uint256 splitTokens = tokensToSwap / 2;
                _selfDistributeDividends(currentRewardToken, splitTokens);
                tokensToSwap -= splitTokens;
            }

            uint256 prevRewardBal = IERC20(currentRewardToken).balanceOf(address(this));
            _SwapDefinitionHook(tokensToSwap,currentRewardToken);

            if (currentRewardToken != address(this)) { //different_token
                uint256 currentRewardBal = IERC20(currentRewardToken).balanceOf(address(this));
                uint256 rewardBal = currentRewardBal != 0 && prevRewardBal != 0 ? currentRewardBal - prevRewardBal : 0;

                if (rewardBal > 0) {
                    //distribute rewards
                    _selfDistributeDividends(currentRewardToken, rewardBal);
                }
            }

            uint256 contractETHBalance = address(this).balance;
            if (contractETHBalance > 0) {
                uint256 splitMarkTokens = (contractETHBalance * MARK_FEE) / BASE_DIVIDER;
                uint256 splitDevTokens = (contractETHBalance * DEV_FEE) / BASE_DIVIDER;
                uint256 splitLprTokens = (contractETHBalance * LPR_FEE) / BASE_DIVIDER;

                if (lprTokens > 0 && splitLprTokens > 0) {
                    addLiquidity(lprTokens, splitLprTokens);
                }

                _sendValueHook(MARK_WALLET, splitMarkTokens);
                _sendValueHook(DEV_WALLET, splitDevTokens);
            }

            uint256 currentTokens = balanceOf(address(this));
            if (currentTokens < prevTokens) {
                swapTokensAmount = 0;
            }

            isNowLiquid = false;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev swap fee tokens to ETH
     * doesn't revert on failure <SWC-113>.
     */
    function _ethSwapHook(uint256 tokenAmount) private returns (bool) {
        bool isSuccess = false;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = UniswapV2Router.WETH();
        _approve(address(this), address(UniswapV2Router), tokenAmount);

        try UniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        ) {
            isSuccess = true;
        } catch Error(string memory /*reason*/) {
            isSuccess = false;
        } catch (bytes memory /*lowLevelData*/) {
            isSuccess = false;
        }
        return isSuccess;
    }

    /**
     * @dev swap ETH fee to tokens
     * doesn't revert on failure <SWC-113>.
     */
    function _tokenSwapHook(uint256 ethAmount, address token) private returns (bool) {
        bool isSuccess = false;
        address[] memory path = new address[](2);
        path[0] = UniswapV2Router.WETH();
        path[1] = token;

        try UniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
            0, 
            path, 
            address(this), 
            block.timestamp
        ) {
            isSuccess = true;
        } catch Error(string memory /*reason*/) {
            isSuccess = false;
        } catch (bytes memory /*lowLevelData*/) {
            isSuccess = false;
        }
        return isSuccess;
    }

    /**
     * @dev _SwapDefinitionHook handle token swaps
     */
    function _SwapDefinitionHook(uint256 tokenAmount, address token) private {
        if (tokenAmount > 0) {
            if (token == address(this)) {
                _ethSwapHook(tokenAmount);
            } else {
                _ethSwapHook(tokenAmount);
                uint256 contractETHBalance = address(this).balance;
                uint256 splitTokens = contractETHBalance / 2;
                if (splitTokens > 0) {
                    _tokenSwapHook(splitTokens, token);
                }
            }
        }
    }

    /**
     * @dev add liquidity to pair
     * doesn't revert on failure <SWC-113>.
     */
    function addLiquidity(uint256 tokenAmount, uint256 ETHAmount) private returns (bool) {
        if (tokenAmount > 0 && ETHAmount > 0) {
            bool isSuccess = false;
            _approve(address(this), address(UniswapV2Router), tokenAmount);

            try UniswapV2Router.addLiquidityETH{value: ETHAmount}(
                address(this),
                tokenAmount,
                0,
                0,
                BURN_WALLET,
                block.timestamp
            ) {
                isSuccess = true;
            } catch Error(string memory /*reason*/) {
                isSuccess = false;
            } catch (bytes memory /*lowLevelData*/) {
                isSuccess = false;
            }
            return isSuccess;
        } else {
            return false;
        }
    }

    /**
     * @dev set minimum amount of tokens before the `liquidSwapProvider` is called.
     */
    function setSwapMinToken(uint256 amount) public onlyOwner {
        require(amount > 0,"ERC20: amount is zero");
        SWAP_MIN_TOKEN = amount;
    }

    /**
     * @dev set whether there should be fees on transactions.
     */
    function setFeeStatus(bool state) public onlyOwner {
        TAKE_FEE = state;
    }

    /**
     * @dev set isNowLiquid for liquidSwapProvider.
     */
    function setIsNowLiquid(bool state) public onlyOwner {
        isNowLiquid = state;
    }

    /**
     * @dev set minimum tx count for liquidSwapProvider.
     */
    function setMinTX(uint256 count) public onlyOwner {
        SWAP_MIN_TX = count;
    }

    /**
     * @dev set current tx count for liquidSwapProvider.
     */
    function setTXCount(uint256 count) public onlyOwner {
        currentTXCount = count;
    }

    /**
     * @dev set whether `liquidSwapProvider` should be called if the requirements are met.
     */
    function setSwapStatus(bool state) public onlyOwner {
        SHOULD_SWAP = state;
    }

    /**
     * @dev set maximum percentage of tokens one wallet can have.
     */
    function setMaxRatio(uint256 ratio) public onlyOwner {
        require((ratio >= MIN_DIVIDER) && (ratio <= BASE_DIVIDER), "ERC20: ratio is zero");
        MAX_RATIO = ratio;
    }

    /**
     * @dev exempt wallet from maximum held limit such is UniswapV2Pair.
     */
    function setExemptHeldList(address[] memory wallets, bool state) public onlyOwner {
        uint256 len = wallets.length;

        for (uint256 i = 0; i < len; i++) {
            isExemptedFromHeld[wallets[i]] = state;
        }
    }

    /**
     * @dev set transaction fee.
     */
    function setTXFee(
        uint256 buyFee,
        uint256 sellFee,
        uint256 usualFee
    ) public onlyOwner {
        require(buyFee <= 700 && sellFee <= 700 && usualFee <= 700, "ERC20: amount exceeds maximum allowed");
        BUY_TX_FEE = buyFee;
        SELL_TX_FEE = sellFee;
        USUAL_TX_FEE = usualFee;
    }

    /**
     * @dev set provider fees.
     */
    function setProviderFee(
        uint256[] memory fees
    ) public onlyOwner {
        uint256 totalFees;
        uint256 len = 4;

        for (uint256 i = 0; i < len; i++) {
            totalFees += fees[i];
        }
        require(totalFees == BASE_DIVIDER, "ERC20: fee is out of scope");

        MARK_FEE = fees[0];
        DEV_FEE = fees[1];
        LPR_FEE = fees[2];
    }

    /**
     * @dev set pair maps for uniswap router or pair.
     */
    function setPairMapList(address[] memory pairs, bool state) public onlyOwner {
        uint256 len = pairs.length;

        for (uint256 i = 0; i < len; i++) {
            address pair = pairs[i];
            if (pair != uniswapV2Pair && pair != address(UniswapV2Router)) {
                pairMap[pair] = state;
            }
        }
    }

    /**
     * @dev set fee wallet for inclusion or exclusion of fees.
     */
    function setFeeWalletList(address[] memory wallets, bool state) public onlyOwner {
        _feeWalletHook(wallets, state);
    }

    /**
     * @dev set provider wallets.
     */
    function setProviderWallets(address payable markWallet, address payable devWallet) public onlyOwner {
        require(_walletVerifyHook(MARK_WALLET) && _walletVerifyHook(DEV_WALLET), "ERC20: wallet not allowed");
        MARK_WALLET = markWallet;
        DEV_WALLET = devWallet;
        address[] memory wallets = new address[](2);
        wallets[0] = markWallet;
        wallets[1] = devWallet;
        _feeWalletHook(wallets, true);
    }

    /**
     * @dev _feeWalletHook to include or exclude wallets for fees.
     */
    function _feeWalletHook(address[] memory wallets, bool state) private {
        uint256 len = wallets.length;

        for (uint256 i = 0; i < len; i++) {
            address wallet = wallets[i];
            isExcludedFromFees[wallet] = state;
        }
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public override(Ownable) onlyOwner {
        require(_walletVerifyHook(newOwner), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev overrides the `renounceOwnership`.
     */
    function renounceOwnership() public override(Ownable) onlyOwner {
        _transferOwnership(owner());
    }

    /// @notice Distributes ether to token holders as dividends.
    /// @dev It reverts if the total supply of tokens is 0.
    /// It emits the `DividendsDistributed` event if the amount of received ether is greater than 0.
    /// About undistributed ether:
    ///   In each distribution, there is a small amount of ether not distributed,
    ///     the magnified amount of which is
    ///     `(msg.value * magnitude) % totalSupply()`. or
    ///     `(token * magnitude) % totalSupply()`
    ///   With a well-chosen `magnitude`, the amount of undistributed ether
    ///     (de-magnified) in a distribution can be less than 1 wei.
    ///   We can actually keep track of the undistributed ether in a distribution
    ///     and try to distribute it in the next distribution,
    ///     but keeping track of such data on-chain costs much more than
    ///     the saved ether, so we don't do that.
    function distributeDividends(address token, uint256 dividendTokenAmount) public onlyOwner {
        require(_dividendTokenSet.contains(token), "ERC20: invalid token");
        require(getReducedSupply() > 0 && dividendTokenAmount > 0, "ERC20: zero value transfer");
        if (token == address(this)) {
            _transfer(_msgSender(), address(this), dividendTokenAmount);
        } else {
            IERC20(token).transferFrom(_msgSender(), address(this), dividendTokenAmount);
        }
        _selfDistributeDividends(token, dividendTokenAmount);
    }

    /**
     * @dev set current reward token for dividends.
     */
    function setCurrentRewardToken(address token) public onlyOwner {
        require(_dividendTokenSet.contains(token) || _dividendTokenSet.length() <= maxTokenLen, "ERC20: token not found reached maxLen");
        if (!_dividendTokenSet.contains(token)) {
            _dividendTokenSet.add(token);
        }
        currentRewardToken = token;
    }

    /**
     * @dev recover ERC20 tokens.
     */
    function recoverERC20(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(_msgSender(), amount);
    }

    /**
     * @dev _preTransferHook: used for pre_transfer actions.
     */
    function _preTransferHook(
        address from, 
        address to, 
        uint256 amount
    ) private returns (bool) {
        require(amount > 0, "ERC20: transfer amount is zero");
        require(from != address(0) && to != address(0), "ERC20: transfer address is zero");
        uint256 actualAmount = amount;
        //anyone who's excludedFromFees = no held limit
        //anyone who's exemptedFromHeld = no held limit
        //no exclusion on router as I see
        //no exclusion on pair (should be exempted) && router?
        if (!isExcludedFromFees[to] && !isExemptedFromHeld[to]) {
            //not excluded or exempted
            require((balanceOf(to) + amount) <= ((totalSupply() * MAX_RATIO) / BASE_DIVIDER), "ERC20: exceeds max holding");
        }

        if (!pairMap[from]) {
            //not a uniswap pair
            _swapProviderHook(); //performs swap and dist if needed
        }

        if (TAKE_FEE && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            //take fee
            uint256 feeAmount;
            if (pairMap[from]) {
                //@isBuy=true
                feeAmount = (amount * BUY_TX_FEE) / BASE_DIVIDER;
            } else if (pairMap[to]) {
                //@isSell=true
                feeAmount = (amount * SELL_TX_FEE) / BASE_DIVIDER;
            }
            else {
                //@isUsual=true
                feeAmount = (amount * USUAL_TX_FEE) / BASE_DIVIDER;
            }
            amount = amount - feeAmount;
            _transfer(from, address(this), feeAmount);
            swapTokensAmount += feeAmount;
        }
        _transfer(from, to, amount); //ordinary transfer
        _postTransferHook(from, to, actualAmount);
        currentTXCount++;
        return true;
    }

    /**
     * @dev _postTransferHook for handling dividends.
     */
    function _postTransferHook(address from, address to, uint256 value) private {
        if (!isExcludedFromReward[from]) {
            _multiTransferHook(from, to, value); //usual correction
        }
    }

    /**
     * @dev _multiTransferHook for handling postTransfer dividends.
     */
    function _multiTransferHook(address from, address to, uint256 value) private {
        address[] memory tokenArray = getDividendTokenList();
        uint256 len = tokenArray.length;

        for (uint256 i = 0; i < len; i++) {
            address token = tokenArray[i];
            int256 _magCorrection = (magnifiedDividendPerShareMap[token] * value).toInt256Safe();
            magnifiedDividendCorrectionsMap[token][from] = magnifiedDividendCorrectionsMap[token][from].add(_magCorrection);
            magnifiedDividendCorrectionsMap[token][to] = magnifiedDividendCorrectionsMap[token][to].sub(_magCorrection);
        }
    }

    /**
     * @dev _initPairCreationHook: create UniswapV2Pair for <Native>:<WETH>.
     */
    function _initPairCreationHook() private returns (bool) {
        uniswapV2Pair = IUniswapV2Factory(UniswapV2Router.factory()).createPair(
            address(this), 
            UniswapV2Router.WETH()
        );
        isExemptedFromHeld[uniswapV2Pair] = true;
        pairMap[uniswapV2Pair] = true;
        return true;
    }

    /**
     * @dev _sendValueHook: doesn't revert on failed ether transfer <SWC-113>.
     */
    function _sendValueHook(address payable recipient, uint256 amount) private returns (bool) {
        bool success = false;
        if (_walletVerifyHook(recipient) && amount > 0) {
            (success, ) = recipient.call{value: amount, gas: 5000}("");
        }
        return success;
    }

    /**
     * @dev _walletVerifyHook: check for potential invalid address.
     */
    function _walletVerifyHook(address wallet) private view returns (bool) {
        return wallet != address(0) &&
               wallet != address(BURN_WALLET) &&
               wallet != address(this) &&
               wallet != address(UniswapV2Router);
    }

    /**
     * @dev _swapProviderHook: check for swap requirements.
     */
    function _swapProviderHook() private returns (bool) {
        if (SHOULD_SWAP && currentTXCount >= SWAP_MIN_TX && swapTokensAmount >= SWAP_MIN_TOKEN) {
            liquidSwapProvider(swapTokensAmount);
        }
        return true;
    }

    /**
     * @dev exclude wallets such as initial from acquiring fees.
     */
    function excludeRewardWallet(address wallet) public onlyOwner {
        if (!isExcludedFromReward[wallet]) {
            isExcludedFromReward[wallet] = true;
            ExclusionRewardList.push(wallet);
        }
    }

    /// @dev internal distributeDividend tokens.
    function _selfDistributeDividends(address token, uint256 dividendTokenAmount) private {
        magnifiedDividendPerShareMap[token] = magnifiedDividendPerShareMap[token] + (
            (dividendTokenAmount) * (MAGNITUDE) / getReducedSupply()        
        );
        emit DividendsDistributed(token, dividendTokenAmount);
    }

    /// @notice Withdraws the ether distributed to the sender.
    /// @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
    function withdrawDividend(address token) public {
        require(!isExcludedFromReward[_msgSender()], "ERC20: excluded from reward");
        require(_dividendTokenSet.contains(token), "ERC20: invalid token");
        uint256 _withdrawableDividend = withdrawableDividendOf(_msgSender(), token);

        if (_withdrawableDividend > 0) {
            withdrawnDividendsMap[token][_msgSender()] = withdrawnDividendsMap[token][_msgSender()] + (_withdrawableDividend);
            emit DividendWithdrawn(_msgSender(), token, _withdrawableDividend);
            if (token == address(this)) {
                _transfer(address(this), _msgSender(), _withdrawableDividend);
            } else {
                IERC20(token).transfer(_msgSender(), _withdrawableDividend);
            }
        }
    }

    /// @dev get dividend token list
    function getDividendTokenList() public view returns (address[] memory) {
        uint256 len = _dividendTokenSet.length();
        address[] memory tokenArray = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            tokenArray[i] = _dividendTokenSet.at(i);
        }

        return tokenArray;
    }

    /// @dev withdrawDividend for all tokens
    function multiWithdrawDividend() public {
        require(!isExcludedFromReward[_msgSender()], "ERC20: excluded from reward");
        address[] memory tokenArray = getDividendTokenList();
        uint256 len = tokenArray.length;

        for (uint256 i = 0; i < len; i++) {
            withdrawDividend(tokenArray[i]);
        }
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function dividendOf(address _owner, address _token) public view returns(uint256) {
        return !isExcludedFromReward[_owner] ? withdrawableDividendOf(_owner, _token) : 0;
    }

    /// @dev dividendOf for all tokens
    function dividendOfAll(address _owner) public view returns(uint256[] memory) {
        address[] memory tokenArray = getDividendTokenList();
        uint256 len = tokenArray.length;
        uint256[] memory variableArray = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address _token = tokenArray[i];
            variableArray[i] = dividendOf(_owner, _token);
        }

        return variableArray;
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function withdrawableDividendOf(address _owner, address _token) public view returns(uint256) {
        return !isExcludedFromReward[_owner] ? accumulativeDividendOf(_owner, _token) - (withdrawnDividendsMap[_token][_owner]) : 0;
    }

    /// @notice View the amount of dividend in wei that an address has withdrawn.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has withdrawn.
    function withdrawnDividendOf(address _owner, address _token) public view returns(uint256) {
        return withdrawnDividendsMap[_token][_owner];
    }

    /// @dev withdrawnDividendOf for all tokens
    function withdrawnDividendOfAll(address _owner) public view returns(uint256[] memory) {
        address[] memory tokenArray = getDividendTokenList();
        uint256 len = tokenArray.length;
        uint256[] memory variableArray = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address _token = tokenArray[i];
            variableArray[i] = withdrawnDividendOf(_owner, _token);
        }

        return variableArray;
    }

    /// @notice View the amount of dividend in wei that an address has earned in total.
    /// @dev accumulativeDividendOf(_owner) = withdrawableDividendOf(_owner) + withdrawnDividendOf(_owner)
    /// = (magnifiedDividendPerShare * balanceOf(_owner) + magnifiedDividendCorrections[_owner]) / magnitude
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has earned in total.
    function accumulativeDividendOf(address _owner, address _token) public view returns(uint256) {    
        return !isExcludedFromReward[_owner] ? magnifiedDividendPerShareMap[_token] * (balanceOf(_owner)).toInt256Safe()
                .add(magnifiedDividendCorrectionsMap[_token][_owner]).toUint256Safe() / MAGNITUDE : 0;
    }

}