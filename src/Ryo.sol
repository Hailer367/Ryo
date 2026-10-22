// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IBalancerVault } from "./interfaces/IBalancerVault.sol";
import { IFlashLoanRecipient } from "./interfaces/IFlashLoanRecipient.sol";
import { ISwapRouter02 } from "./interfaces/ISwapRouter02.sol";
import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";
import { IAerodromeRouter } from "./interfaces/IAerodromeRouter.sol";
import { ISlipstreamSwapRouter } from "./interfaces/ISlipstreamSwapRouter.sol";

/// @title Ryo
/// @notice Atomic Balancer flash-loan arbitrage executor for Base.
/// @dev The owner is an admin hot wallet; the operator is a separate hot wallet used by the
///      watcher bot. Both are ordinary EOAs today and can later be replaced by a multisig.
///
///      Route model:
///      - Two immutable primary routes (fast path, minimum calldata).
///      - One parameterized route with an arbitrary number of swaps (>= 2).
///
///      The contract never holds funds between executions. Profit is measured in the borrowed
///      asset as a balance delta after the Vault has pulled repayment, then sent to the owner.
contract Ryo is IFlashLoanRecipient, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------------------------------
    // DEX type ids
    // --------------------------------------------------------------------------------------------

    /// @notice Uniswap V3 / SwapRouter02-style adapter.
    uint8 public constant DEX_UNISWAP_V3 = 6;

    /// @notice Uniswap V2-style adapter (`swapExactTokensForTokens`).
    uint8 public constant DEX_UNISWAP_V2 = 8;

    /// @notice Aerodrome classic adapter (volatile and stable pools).
    /// @dev Aerodrome's router takes a list of route hops instead of a plain token path.
    uint8 public constant DEX_AERODROME = 4;

    /// @notice Aerodrome Slipstream adapter (concentrated liquidity).
    /// @dev Slipstream identifies pools by tick spacing instead of a Uniswap V3 fee tier.
    uint8 public constant DEX_SLIPSTREAM = 7;

    // Reserved for future adapters. Do NOT reuse these ids.
    // 1 = canonical Uniswap V2
    // 2 = SushiSwap V2
    // 3 = PancakeSwap V2
    // 5 = Curve
    // 9 = WOOFi
    // 10 = Maverick
    // 11 = Algebra (concentrated liquidity with yet another router ABI)
    // 12..255 = free

    // --------------------------------------------------------------------------------------------
    // Types
    // --------------------------------------------------------------------------------------------

    /// @notice One parameterized swap. `extraData` is adapter-specific; see WATCHER_INTERFACE.md.
    struct Swap {
        uint8 dexType;
        address router;
        address tokenIn;
        address tokenOut;
        bytes extraData;
    }

    /// @notice Immutable primary-route configuration returned by `primaryRoute`.
    /// @dev `asset == address(0)` means the route is disabled.
    struct PrimaryRouteConfig {
        address asset;
        address intermediate;
        address buyRouter;
        address sellRouter;
        uint8 buyDexType;
        uint8 sellDexType;
        uint24 buyFee;
        uint24 sellFee;
    }

    // --------------------------------------------------------------------------------------------
    // Errors
    // --------------------------------------------------------------------------------------------

    error NotOperator(address caller);
    error ContractPaused();
    error AlreadyPaused();
    error NotPaused();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRouteId(uint8 routeId);
    error RouteTooShort();
    error RouteMismatch(uint256 index);
    error InvalidSwap(uint256 index);
    error RouterNotWhitelisted(address router);
    error UnsupportedDexType(uint8 dexType);
    error InvalidExtraData(uint256 index);
    error InvalidPath(uint256 index);
    error UnauthorizedCallback();
    error UnexpectedCallback();
    error InvalidFlashLoanData();
    error InsufficientProfit(uint256 minProfit, int256 actualProfit);
    error TradeSizeExceeded(address asset, uint256 amount, uint256 maxAmount);
    error GasPriceTooHigh(uint256 maxGasPrice, uint256 actualGasPrice);
    error SwapBalanceDecreased(uint256 index);
    error InsufficientOutput(uint256 index, uint256 minOut, uint256 actualOut);
    error InvalidPrimaryRoute(uint8 routeId);
    error EthTransferFailed();

    /// @notice Simulation result. Always reverts with this so eth_call can decode the profit.
    /// @dev Positive = profit; negative = loss. Units are the borrowed asset's smallest unit.
    error SimulationResult(int256 profit);

    // --------------------------------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------------------------------

    event PrimaryExecuted(
        address indexed operator,
        uint8 indexed routeId,
        address indexed asset,
        uint256 amountBorrowed,
        uint256 profit
    );

    event ArbitrageExecuted(
        address indexed operator,
        address indexed asset,
        uint256 amountBorrowed,
        uint256 profit,
        uint256 swapCount
    );

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event RouterWhitelistUpdated(address indexed router, bool allowed);
    event MaxTradeSizeUpdated(address indexed asset, uint256 maxAmount);
    event MaxGasPriceUpdated(uint256 maxGasPrice);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event EthRescued(address indexed to, uint256 amount);

    // --------------------------------------------------------------------------------------------
    // Immutables and storage
    // --------------------------------------------------------------------------------------------

    IBalancerVault public immutable vault;

    // Primary route 0 (all fields immutable; code-embedded, no storage reads on the hot path).
    address private immutable _p0Asset;
    address private immutable _p0Intermediate;
    address private immutable _p0BuyRouter;
    address private immutable _p0SellRouter;
    uint8 private immutable _p0BuyDexType;
    uint8 private immutable _p0SellDexType;
    uint24 private immutable _p0BuyFee;
    uint24 private immutable _p0SellFee;

    // Primary route 1.
    address private immutable _p1Asset;
    address private immutable _p1Intermediate;
    address private immutable _p1BuyRouter;
    address private immutable _p1SellRouter;
    uint8 private immutable _p1BuyDexType;
    uint8 private immutable _p1SellDexType;
    uint24 private immutable _p1BuyFee;
    uint24 private immutable _p1SellFee;

    /// @notice Hot wallet allowed to execute, simulate, and pause.
    address public operator;

    /// @notice Execution kill switch.
    bool public paused;

    /// @notice Maximum tx.gasprice accepted by execution. Zero disables the check.
    uint256 public maxGasPrice;

    /// @notice Router whitelist. Only owner-mutable.
    mapping(address router => bool allowed) public isRouterWhitelisted;

    /// @notice Per-borrowed-asset cap. Zero means unlimited.
    mapping(address asset => uint256 maxAmount) public maxTradeSize;

    // Transient state (EIP-1153). Base supports Cancun.
    // The hash binds the callback to the exact userData this contract requested. The consumed flag
    // prevents a second callback in the same transaction. Neither survives the transaction.
    bytes32 private transient _expectedUserDataHash;
    address private transient _activeAsset;
    uint256 private transient _activeAmount;
    bool private transient _simulationMode;
    bool private transient _callbackConsumed;
    uint256 private transient _simulationBalanceBefore;

    // --------------------------------------------------------------------------------------------
    // Modifiers
    // --------------------------------------------------------------------------------------------

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // --------------------------------------------------------------------------------------------
    // Constructor
    // --------------------------------------------------------------------------------------------

    /// @param vault_ Balancer V2 Vault (Base: 0xBA12222222228d8Ba445958a75a0704d566BF2C8).
    /// @param initialOwner Owner/admin address (two-step transfer supported).
    /// @param initialOperator Watcher hot-wallet address.
    /// @param route0 Primary route 0. Set `asset` to zero to disable.
    /// @param route1 Primary route 1. Set `asset` to zero to disable.
    /// @param initialRouters Extra routers to whitelist at deploy (primary routers are automatic).
    /// @param initialMaxGasPrice Zero disables the gas-price check.
    /// @param route0MaxTradeSize Per-asset cap for route 0's asset (zero = unlimited).
    /// @param route1MaxTradeSize Per-asset cap for route 1's asset (zero = unlimited).
    constructor(
        address vault_,
        address initialOwner,
        address initialOperator,
        PrimaryRouteConfig memory route0,
        PrimaryRouteConfig memory route1,
        address[] memory initialRouters,
        uint256 initialMaxGasPrice,
        uint256 route0MaxTradeSize,
        uint256 route1MaxTradeSize
    ) Ownable(initialOwner) {
        if (vault_ == address(0) || initialOperator == address(0)) {
            revert ZeroAddress();
        }

        vault = IBalancerVault(vault_);
        operator = initialOperator;
        maxGasPrice = initialMaxGasPrice;

        _validatePrimaryRoute(0, route0);
        _p0Asset = route0.asset;
        _p0Intermediate = route0.intermediate;
        _p0BuyRouter = route0.buyRouter;
        _p0SellRouter = route0.sellRouter;
        _p0BuyDexType = route0.buyDexType;
        _p0SellDexType = route0.sellDexType;
        _p0BuyFee = route0.buyFee;
        _p0SellFee = route0.sellFee;

        _validatePrimaryRoute(1, route1);
        _p1Asset = route1.asset;
        _p1Intermediate = route1.intermediate;
        _p1BuyRouter = route1.buyRouter;
        _p1SellRouter = route1.sellRouter;
        _p1BuyDexType = route1.buyDexType;
        _p1SellDexType = route1.sellDexType;
        _p1BuyFee = route1.buyFee;
        _p1SellFee = route1.sellFee;

        _whitelistPrimaryRouters(route0);
        _whitelistPrimaryRouters(route1);

        uint256 len = initialRouters.length;
        for (uint256 i = 0; i < len;) {
            address router = initialRouters[i];
            if (router == address(0)) revert ZeroAddress();
            isRouterWhitelisted[router] = true;
            emit RouterWhitelistUpdated(router, true);
            unchecked {
                ++i;
            }
        }

        if (route0.asset != address(0) && route0MaxTradeSize != 0) {
            maxTradeSize[route0.asset] = route0MaxTradeSize;
            emit MaxTradeSizeUpdated(route0.asset, route0MaxTradeSize);
        }
        if (route1.asset != address(0) && route1MaxTradeSize != 0) {
            maxTradeSize[route1.asset] = route1MaxTradeSize;
            emit MaxTradeSizeUpdated(route1.asset, route1MaxTradeSize);
        }

        emit OperatorUpdated(address(0), initialOperator);
        emit MaxGasPriceUpdated(initialMaxGasPrice);
    }

    // --------------------------------------------------------------------------------------------
    // Execution
    // --------------------------------------------------------------------------------------------

    /// @notice Execute an arbitrary coherent route through a Balancer flash loan.
    /// @param asset Borrowed asset; must be the first tokenIn and final tokenOut.
    /// @param amount Amount to borrow.
    /// @param swaps Route. At least two swaps; tokenIn/tokenOut must chain.
    /// @param minProfit Minimum profit in `asset` after repayment. Reverts if not met.
    /// @return profit Profit sent to the owner.
    function execute(address asset, uint256 amount, Swap[] calldata swaps, uint256 minProfit)
        external
        nonReentrant
        onlyOperator
        whenNotPaused
        returns (uint256 profit)
    {
        _checkGasPrice();
        _validateRoute(asset, amount, swaps);

        bytes memory userData = abi.encode(swaps);
        int256 result = _run(asset, amount, userData, false);

        if (result < 0) revert InsufficientProfit(minProfit, result);
        profit = uint256(result);
        if (profit < minProfit) revert InsufficientProfit(minProfit, result);

        if (profit != 0) IERC20(asset).safeTransfer(owner(), profit);

        emit ArbitrageExecuted(msg.sender, asset, amount, profit, swaps.length);
    }

    /// @notice Execute one of the two immutable primary routes. Minimum-calldata fast path.
    /// @param routeId 0 or 1.
    /// @param amount Amount to borrow.
    /// @param minProfit Minimum profit in the route asset after repayment.
    function executePrimary(uint8 routeId, uint256 amount, uint256 minProfit)
        external
        nonReentrant
        onlyOperator
        whenNotPaused
        returns (uint256 profit)
    {
        _checkGasPrice();

        PrimaryRouteConfig memory route = _primaryRoute(routeId);
        address asset = route.asset;
        if (asset == address(0)) revert InvalidRouteId(routeId);
        if (amount == 0) revert ZeroAmount();
        _checkTradeSize(asset, amount);
        if (!isRouterWhitelisted[route.buyRouter]) revert RouterNotWhitelisted(route.buyRouter);
        if (!isRouterWhitelisted[route.sellRouter]) revert RouterNotWhitelisted(route.sellRouter);

        // One byte of userData: the route id. The callback hash binds it to this call.
        bytes memory userData = abi.encodePacked(routeId);
        int256 result = _run(asset, amount, userData, false);

        if (result < 0) revert InsufficientProfit(minProfit, result);
        profit = uint256(result);
        if (profit < minProfit) revert InsufficientProfit(minProfit, result);

        if (profit != 0) IERC20(asset).safeTransfer(owner(), profit);

        emit PrimaryExecuted(msg.sender, routeId, asset, amount, profit);
    }

    // --------------------------------------------------------------------------------------------
    // Simulation (eth_call only; always reverts)
    // --------------------------------------------------------------------------------------------

    /// @notice Simulate a parameterized route. Always reverts with `SimulationResult(int256 profit)`.
    /// @dev For negative-profit routes the callback reverts with `SimulationResult` before the Vault
    ///      tries to pull an unaffordable repayment. For profitable routes the full repayment runs,
    ///      then this function reverts with the measured profit. No state survives the eth_call.
    function simulate(address asset, uint256 amount, Swap[] calldata swaps)
        external
        nonReentrant
        onlyOperator
    {
        _validateRoute(asset, amount, swaps);
        bytes memory userData = abi.encode(swaps);
        int256 result = _run(asset, amount, userData, true);
        revert SimulationResult(result);
    }

    /// @notice Simulate a primary route. Always reverts with `SimulationResult(int256 profit)`.
    function simulatePrimary(uint8 routeId, uint256 amount) external nonReentrant onlyOperator {
        PrimaryRouteConfig memory route = _primaryRoute(routeId);
        address asset = route.asset;
        if (asset == address(0)) revert InvalidRouteId(routeId);
        if (amount == 0) revert ZeroAmount();
        _checkTradeSize(asset, amount);
        if (!isRouterWhitelisted[route.buyRouter]) revert RouterNotWhitelisted(route.buyRouter);
        if (!isRouterWhitelisted[route.sellRouter]) revert RouterNotWhitelisted(route.sellRouter);

        bytes memory userData = abi.encodePacked(routeId);
        int256 result = _run(asset, amount, userData, true);
        revert SimulationResult(result);
    }

    // --------------------------------------------------------------------------------------------
    // Balancer callback
    // --------------------------------------------------------------------------------------------

    /// @inheritdoc IFlashLoanRecipient
    /// @dev Security:
    ///      1. msg.sender must be the Vault.
    ///      2. The transient hash must equal keccak256(userData) set immediately before flashLoan.
    ///      3. A transient consumed flag rejects a second callback.
    ///      4. Borrowed token/amount must match the transient expected values.
    ///      Together these reject direct calls, fake-vault calls, and callbacks not started by this
    ///      contract's execute/simulate flow. A malicious router cannot re-enter because the
    ///      consumed flag is already set and the reentrancy guard covers the outer call.
    ///
    ///      Repayment: Balancer V2 does not pull tokens via allowance. It transfers the loan to the
    ///      recipient, calls this hook, then verifies its own balance is at least the pre-loan
    ///      balance plus fees. This hook therefore transfers `amount + fee` back explicitly.
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (msg.sender != address(vault)) revert UnauthorizedCallback();
        if (_callbackConsumed) revert UnexpectedCallback();

        bytes32 expected = _expectedUserDataHash;
        if (expected == bytes32(0) || keccak256(userData) != expected) revert UnexpectedCallback();
        _callbackConsumed = true;

        if (tokens.length != 1 || amounts.length != 1 || feeAmounts.length != 1) {
            revert InvalidFlashLoanData();
        }

        address asset = address(tokens[0]);
        uint256 amount = amounts[0];
        if (asset != _activeAsset || amount != _activeAmount || asset == address(0)) {
            revert InvalidFlashLoanData();
        }

        if (userData.length == 1) {
            _executePrimarySwaps(uint8(userData[0]), amount, asset);
        } else {
            Swap[] memory swaps = abi.decode(userData, (Swap[]));
            _executeSwaps(swaps, amount, asset);
        }

        uint256 repay = amount + feeAmounts[0];

        // Simulation only: report a loss before attempting an unaffordable repayment. Subtract any
        // pre-existing dust so the result matches the balance-delta profit measured by `_run`.
        if (_simulationMode) {
            int256 p = int256(IERC20(asset).balanceOf(address(this))) - int256(repay)
                - int256(_simulationBalanceBefore);
            if (p < 0) revert SimulationResult(p);
        }

        // Balancer V2 does not pull repayment: it checks its balance after this callback returns.
        // Transfer the borrowed amount plus fee back to the Vault before returning.
        IERC20(asset).safeTransfer(address(vault), repay);
    }

    // --------------------------------------------------------------------------------------------
    // Internal flash-loan orchestration
    // --------------------------------------------------------------------------------------------

    /// @dev Runs one flash loan and returns the balance delta in `asset` after repayment.
    ///      `simulation` only changes how a negative result is surfaced.
    function _run(address asset, uint256 amount, bytes memory userData, bool simulation)
        private
        returns (int256 profit)
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _expectedUserDataHash = keccak256(userData);
        _activeAsset = asset;
        _activeAmount = amount;
        _simulationMode = simulation;
        _simulationBalanceBefore = simulation ? balanceBefore : 0;
        _callbackConsumed = false;

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(asset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vault.flashLoan(this, tokens, amounts, userData);

        // A compliant Vault always calls the callback. Reject a silent/no-op Vault.
        if (!_callbackConsumed) revert UnexpectedCallback();

        _expectedUserDataHash = bytes32(0);
        _activeAsset = address(0);
        _activeAmount = 0;
        _simulationMode = false;
        _simulationBalanceBefore = 0;

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        profit = int256(balanceAfter) - int256(balanceBefore);
    }

    // --------------------------------------------------------------------------------------------
    // Internal route validation
    // --------------------------------------------------------------------------------------------

    function _validateRoute(address asset, uint256 amount, Swap[] calldata swaps) private view {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _checkTradeSize(asset, amount);

        uint256 len = swaps.length;
        if (len < 2) revert RouteTooShort();

        address previousOut = asset;
        for (uint256 i = 0; i < len;) {
            Swap calldata s = swaps[i];

            if (s.tokenIn != previousOut) revert RouteMismatch(i);
            if (s.tokenIn == s.tokenOut) revert InvalidSwap(i);

            address router = s.router;
            if (router == address(0) || !isRouterWhitelisted[router]) {
                revert RouterNotWhitelisted(router);
            }

            uint8 dexType = s.dexType;
            if (!_isSupportedDexType(dexType)) {
                revert UnsupportedDexType(dexType);
            }

            _validateExtraData(s, i);
            previousOut = s.tokenOut;

            unchecked {
                ++i;
            }
        }

        if (previousOut != asset) revert RouteMismatch(len);
    }

    function _validateExtraData(Swap calldata s, uint256 index) private pure {
        uint8 dexType = s.dexType;

        if (dexType == DEX_UNISWAP_V3) {
            uint256 v3Len = s.extraData.length;
            // abi.encode(uint24 fee) or abi.encode(uint24 fee, uint256 minAmountOut)
            if (v3Len != 32 && v3Len != 64) revert InvalidExtraData(index);
            return;
        }

        if (dexType == DEX_SLIPSTREAM) {
            uint256 slLen = s.extraData.length;
            // abi.encode(int24 tickSpacing) or abi.encode(int24 tickSpacing, uint256 minAmountOut)
            if (slLen != 32 && slLen != 64) revert InvalidExtraData(index);
            return;
        }

        if (dexType == DEX_AERODROME) {
            uint256 aeroLen = s.extraData.length;
            // abi.encode(address[] path, bool[] stablePerHop, uint256 minAmountOut)
            if (aeroLen < 256 || aeroLen % 32 != 0) revert InvalidExtraData(index);

            (address[] memory path, bool[] memory stablePerHop) =
                abi.decode(s.extraData, (address[], bool[]));
            uint256 pathLen = path.length;
            if (stablePerHop.length != pathLen - 1) revert InvalidPath(index);
            _validatePath(path, s.tokenIn, s.tokenOut, index);
            // Canonical encoding only: two offsets, the output floor, and two array lengths, plus
            // one word per path entry and per hop flag.
            if (aeroLen != 32 * (5 + pathLen + stablePerHop.length)) {
                revert InvalidExtraData(index);
            }
            return;
        }

        // dexType == DEX_UNISWAP_V2
        uint256 v2Len = s.extraData.length;
        if (v2Len == 0) return; // direct tokenIn -> tokenOut pair, minOut = 1

        // abi.encode(address[] path, uint256 minAmountOut):
        // 32-byte offset + 32-byte minOut + 32-byte length + at least 2 addresses.
        if (v2Len < 160 || v2Len % 32 != 0) revert InvalidExtraData(index);

        address[] memory path = abi.decode(s.extraData, (address[]));
        _validatePath(path, s.tokenIn, s.tokenOut, index);
    }

    /// @dev Shared path check: at least two tokens, no zero addresses, and the path must start at
    ///      `tokenIn` and end at `tokenOut`.
    function _validatePath(address[] memory path, address tokenIn, address tokenOut, uint256 index)
        private
        pure
    {
        uint256 pathLen = path.length;
        if (pathLen < 2 || path[0] != tokenIn || path[pathLen - 1] != tokenOut) {
            revert InvalidPath(index);
        }
        for (uint256 j = 0; j < pathLen;) {
            if (path[j] == address(0)) revert InvalidPath(index);
            unchecked {
                ++j;
            }
        }
    }

    function _checkTradeSize(address asset, uint256 amount) private view {
        uint256 maxAmount = maxTradeSize[asset];
        if (maxAmount != 0 && amount > maxAmount) {
            revert TradeSizeExceeded(asset, amount, maxAmount);
        }
    }

    function _checkGasPrice() private view {
        uint256 max = maxGasPrice;
        if (max != 0 && tx.gasprice > max) revert GasPriceTooHigh(max, tx.gasprice);
    }

    // --------------------------------------------------------------------------------------------
    // Internal swap execution
    // --------------------------------------------------------------------------------------------

    /// @dev Re-validates the decoded dynamic route defensively before spending loaned funds.
    function _executeSwaps(Swap[] memory swaps, uint256 amount, address asset) private {
        uint256 len = swaps.length;
        if (len < 2) revert RouteTooShort();

        address previousOut = asset;
        uint256 amountIn = amount;

        for (uint256 i = 0; i < len;) {
            Swap memory s = swaps[i];

            if (s.tokenIn != previousOut) revert RouteMismatch(i);
            if (s.tokenIn == s.tokenOut) revert InvalidSwap(i);
            if (!isRouterWhitelisted[s.router]) revert RouterNotWhitelisted(s.router);

            amountIn = _dispatch(s, amountIn, i);
            previousOut = s.tokenOut;

            unchecked {
                ++i;
            }
        }

        if (previousOut != asset) revert RouteMismatch(len);
    }

    function _executePrimarySwaps(uint8 routeId, uint256 amount, address asset) private {
        PrimaryRouteConfig memory r = _primaryRoute(routeId);
        if (r.asset != asset) revert InvalidFlashLoanData();

        address buyRouter = r.buyRouter;
        address sellRouter = r.sellRouter;
        if (!isRouterWhitelisted[buyRouter]) revert RouterNotWhitelisted(buyRouter);
        if (!isRouterWhitelisted[sellRouter]) revert RouterNotWhitelisted(sellRouter);

        uint256 out;
        if (r.buyDexType == DEX_UNISWAP_V3) {
            out = _swapV3(buyRouter, r.asset, r.intermediate, r.buyFee, amount, 1, 0);
        } else if (r.buyDexType == DEX_UNISWAP_V2) {
            out = _swapV2Direct(buyRouter, r.asset, r.intermediate, amount, 1, 0);
        } else {
            revert UnsupportedDexType(r.buyDexType);
        }

        if (r.sellDexType == DEX_UNISWAP_V3) {
            _swapV3(sellRouter, r.intermediate, r.asset, r.sellFee, out, 1, 1);
        } else if (r.sellDexType == DEX_UNISWAP_V2) {
            _swapV2Direct(sellRouter, r.intermediate, r.asset, out, 1, 1);
        } else {
            revert UnsupportedDexType(r.sellDexType);
        }
    }

    function _dispatch(Swap memory s, uint256 amountIn, uint256 index)
        private
        returns (uint256 amountOut)
    {
        uint8 dexType = s.dexType;

        if (dexType == DEX_UNISWAP_V3) {
            (uint24 fee, uint256 minOut) = _decodeV3Extra(s.extraData);
            return _swapV3(s.router, s.tokenIn, s.tokenOut, fee, amountIn, minOut, index);
        }

        if (dexType == DEX_UNISWAP_V2) {
            (address[] memory path, uint256 minOut) = _v2Params(s, index);
            return _swapV2Path(s.router, path, s.tokenIn, s.tokenOut, amountIn, minOut, index);
        }

        if (dexType == DEX_AERODROME) {
            (address[] memory path, bool[] memory stablePerHop, uint256 minOut) =
                _aerodromeParams(s, index);
            return _swapAerodrome(
                s.router, path, stablePerHop, s.tokenIn, s.tokenOut, amountIn, minOut, index
            );
        }

        if (dexType == DEX_SLIPSTREAM) {
            (int24 tickSpacing, uint256 minOut) = _decodeSlipstreamExtra(s.extraData);
            return _swapSlipstream(
                s.router, s.tokenIn, s.tokenOut, tickSpacing, amountIn, minOut, index
            );
        }

        revert UnsupportedDexType(dexType);
    }

    /// @dev Aerodrome classic swap (volatile and stable pools).
    ///
    ///      Aerodrome's router pulls the input token from this contract, so the router is approved
    ///      for the exact input amount. The router takes one hop per pair of path entries, and each
    ///      hop states whether its pool is a stable (pegged) pool or a volatile one. The pool
    ///      factory is left as address(0), which means "the router's default factory".
    function _swapAerodrome(
        address router,
        address[] memory path,
        bool[] memory stablePerHop,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 index
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        uint256 hops = path.length - 1;
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](hops);
        for (uint256 i = 0; i < hops;) {
            routes[i] = IAerodromeRouter.Route({
                from: path[i], to: path[i + 1], stable: stablePerHop[i], factory: address(0)
            });
            unchecked {
                ++i;
            }
        }

        IAerodromeRouter(router)
            .swapExactTokensForTokens(amountIn, minOut, routes, address(this), block.timestamp);

        return _settle(tokenIn, tokenOut, router, balanceBefore, minOut, index);
    }

    /// @dev Aerodrome Slipstream swap (concentrated liquidity).
    ///
    ///      Slipstream identifies a pool by its tick spacing rather than a Uniswap V3 fee tier,
    ///      and its router carries a deadline field that Uniswap's does not. The router pulls the
    ///      input token from this contract, so the router is approved for the exact input amount.
    function _swapSlipstream(
        address router,
        address tokenIn,
        address tokenOut,
        int24 tickSpacing,
        uint256 amountIn,
        uint256 minOut,
        uint256 index
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        ISlipstreamSwapRouter(router)
            .exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    tickSpacing: tickSpacing,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );

        return _settle(tokenIn, tokenOut, router, balanceBefore, minOut, index);
    }

    /// @dev Approve exact amount, swap, reset approval, and measure output by balance difference.
    ///      `minOut` is an absolute amount in tokenOut units and is always at least 1.
    function _swapV3(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut,
        uint256 index
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        _callExactInputSingle(router, tokenIn, tokenOut, fee, amountIn, minOut);

        return _settle(tokenIn, tokenOut, router, balanceBefore, minOut, index);
    }

    function _swapV2Direct(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 index
    ) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return _swapV2Path(router, path, tokenIn, tokenOut, amountIn, minOut, index);
    }

    function _swapV2Path(
        address router,
        address[] memory path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 index
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IUniswapV2Router02(router)
            .swapExactTokensForTokens(amountIn, minOut, path, address(this), block.timestamp);

        return _settle(tokenIn, tokenOut, router, balanceBefore, minOut, index);
    }

    /// @dev Shared tail of every adapter: measure the real output by balance difference, reset the
    ///      router approval, and enforce the non-zero output floor.
    function _settle(
        address tokenIn,
        address tokenOut,
        address router,
        uint256 balanceBefore,
        uint256 minOut,
        uint256 index
    ) private returns (uint256 amountOut) {
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));

        _resetApproval(tokenIn, router);

        if (balanceAfter < balanceBefore) revert SwapBalanceDecreased(index);
        amountOut = balanceAfter - balanceBefore;
        if (amountOut < minOut) revert InsufficientOutput(index, minOut, amountOut);
    }

    /// @dev Gas-optimized SwapRouter02 `exactInputSingle` call.
    ///
    ///      ABI: selector (4 bytes) followed by seven 32-byte static words:
    ///      tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96.
    ///      Total calldata: 4 + 7*32 = 228 bytes (0xe4).
    ///
    ///      This writes the calldata directly into freshly allocated memory instead of asking the
    ///      ABI encoder to build a struct and copy it (saves ~200-300 gas per V3 swap). The call's
    ///      return value is deliberately ignored: the caller measures the real output via balance
    ///      difference, which is resistant to non-standard return data.
    ///
    ///      Differential tests in test/RyoAssembly.t.sol compare this path against a plain
    ///      Solidity reference (`ISwapRouter02.exactInputSingle`) byte-for-byte and on a Base fork.
    function _callExactInputSingle(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) internal {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0xe4))

            // Selector 0x04e45aaf: exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))
            mstore(ptr, shl(224, 0x04e45aaf))
            mstore(add(ptr, 0x04), tokenIn)
            mstore(add(ptr, 0x24), tokenOut)
            mstore(add(ptr, 0x44), fee)
            mstore(add(ptr, 0x64), address())
            mstore(add(ptr, 0x84), amountIn)
            mstore(add(ptr, 0xa4), minOut)
            mstore(add(ptr, 0xc4), 0)

            if iszero(call(gas(), router, 0, ptr, 0xe4, 0, 0)) {
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    /// @dev Reset an allowance to zero only if it is still non-zero. Standard ERC20 routers/Vaults
    ///      consume the exact allowance, so this skips a redundant approve() call on the hot path.
    function _resetApproval(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) != 0) {
            IERC20(token).forceApprove(spender, 0);
        }
    }

    // --------------------------------------------------------------------------------------------
    // Extra-data decoding
    // --------------------------------------------------------------------------------------------

    /// @dev dexType 6 extraData:
    ///      - 32 bytes: abi.encode(uint24 fee); minOut defaults to 1.
    ///      - 64 bytes: abi.encode(uint24 fee, uint256 minAmountOut).
    ///
    ///      An assembly version of this decoder was written and measured against this plain one
    ///      (test/RyoAssembly.t.sol). It came out 22 gas *slower*, so the plain decoder was kept.
    ///      The plain version also rejects non-canonical encodings instead of silently masking
    ///      the high bits of the fee.
    function _decodeV3Extra(bytes memory data) internal pure returns (uint24 fee, uint256 minOut) {
        uint256 len = data.length;
        if (len == 32) {
            fee = abi.decode(data, (uint24));
            minOut = 1;
        } else if (len == 64) {
            (fee, minOut) = abi.decode(data, (uint24, uint256));
            if (minOut == 0) minOut = 1;
        } else {
            revert InvalidExtraData(0);
        }
    }

    /// @dev dexType 8 extraData:
    ///      - empty: direct tokenIn -> tokenOut pair, minOut = 1.
    ///      - abi.encode(address[] path, uint256 minAmountOut): custom path, minOut >= 1.
    function _v2Params(Swap memory s, uint256 index)
        private
        pure
        returns (address[] memory path, uint256 minOut)
    {
        if (s.extraData.length == 0) {
            path = new address[](2);
            path[0] = s.tokenIn;
            path[1] = s.tokenOut;
            minOut = 1;
            return (path, minOut);
        }

        (path, minOut) = abi.decode(s.extraData, (address[], uint256));
        if (minOut == 0) minOut = 1;

        _validatePath(path, s.tokenIn, s.tokenOut, index);
    }

    /// @dev dexType 4 extraData:
    ///      - abi.encode(address[] path, bool[] stablePerHop, uint256 minAmountOut)
    ///
    ///      `path` is the token chain. `stablePerHop[i]` marks hop i (path[i] -> path[i+1]) as a
    ///      stable pool when true and a volatile pool when false. `stablePerHop.length` must be
    ///      exactly `path.length - 1`.
    function _aerodromeParams(Swap memory s, uint256 index)
        private
        pure
        returns (address[] memory path, bool[] memory stablePerHop, uint256 minOut)
    {
        (path, stablePerHop, minOut) = abi.decode(s.extraData, (address[], bool[], uint256));

        uint256 pathLen = path.length;
        if (stablePerHop.length != pathLen - 1) revert InvalidPath(index);
        _validatePath(path, s.tokenIn, s.tokenOut, index);

        // Canonical encoding only: two offsets, the output floor, and two array lengths, plus one
        // word per path entry and per hop flag.
        if (s.extraData.length != 32 * (5 + pathLen + stablePerHop.length)) {
            revert InvalidExtraData(index);
        }

        if (minOut == 0) minOut = 1;
    }

    /// @dev dexType 7 extraData:
    ///      - 32 bytes: abi.encode(int24 tickSpacing); minOut defaults to 1.
    ///      - 64 bytes: abi.encode(int24 tickSpacing, uint256 minAmountOut).
    ///      Plain decoding is used here because the tick spacing is a signed value: hand-rolled
    ///      assembly would have to sign-extend it, and this path is not hot enough to justify that.
    function _decodeSlipstreamExtra(bytes memory data)
        private
        pure
        returns (int24 tickSpacing, uint256 minOut)
    {
        uint256 len = data.length;
        if (len == 32) {
            tickSpacing = abi.decode(data, (int24));
            minOut = 1;
        } else if (len == 64) {
            (tickSpacing, minOut) = abi.decode(data, (int24, uint256));
            if (minOut == 0) minOut = 1;
        } else {
            revert InvalidExtraData(0);
        }
    }

    // --------------------------------------------------------------------------------------------
    // Primary route views
    // --------------------------------------------------------------------------------------------

    /// @notice Read the immutable configuration of a primary route.
    /// @dev `asset == address(0)` means the route is disabled.
    function primaryRoute(uint8 routeId) public view returns (PrimaryRouteConfig memory) {
        return _primaryRoute(routeId);
    }

    function _primaryRoute(uint8 routeId) private view returns (PrimaryRouteConfig memory r) {
        if (routeId == 0) {
            r.asset = _p0Asset;
            r.intermediate = _p0Intermediate;
            r.buyRouter = _p0BuyRouter;
            r.sellRouter = _p0SellRouter;
            r.buyDexType = _p0BuyDexType;
            r.sellDexType = _p0SellDexType;
            r.buyFee = _p0BuyFee;
            r.sellFee = _p0SellFee;
            return r;
        }
        if (routeId == 1) {
            r.asset = _p1Asset;
            r.intermediate = _p1Intermediate;
            r.buyRouter = _p1BuyRouter;
            r.sellRouter = _p1SellRouter;
            r.buyDexType = _p1BuyDexType;
            r.sellDexType = _p1SellDexType;
            r.buyFee = _p1BuyFee;
            r.sellFee = _p1SellFee;
            return r;
        }
        revert InvalidRouteId(routeId);
    }

    /// @notice True for dexType ids implemented in this deployment.
    /// @dev 6 = Uniswap V3 / SwapRouter02, 8 = Uniswap V2-style, 4 = Aerodrome classic,
    ///      7 = Aerodrome Slipstream (concentrated liquidity).
    function isSupportedDexType(uint8 dexType) external pure returns (bool) {
        return _isSupportedDexType(dexType);
    }

    function _isSupportedDexType(uint8 dexType) private pure returns (bool) {
        return dexType == DEX_UNISWAP_V3 || dexType == DEX_UNISWAP_V2 || dexType == DEX_AERODROME
            || dexType == DEX_SLIPSTREAM;
    }

    function _validatePrimaryRoute(uint8 routeId, PrimaryRouteConfig memory r) private pure {
        if (r.asset == address(0)) return; // disabled route

        if (r.intermediate == address(0) || r.intermediate == r.asset) {
            revert InvalidPrimaryRoute(routeId);
        }
        if (r.buyRouter == address(0) || r.sellRouter == address(0)) revert ZeroAddress();
        if (
            (r.buyDexType != DEX_UNISWAP_V3 && r.buyDexType != DEX_UNISWAP_V2)
                || (r.sellDexType != DEX_UNISWAP_V3 && r.sellDexType != DEX_UNISWAP_V2)
        ) {
            revert UnsupportedDexType(r.buyDexType != DEX_UNISWAP_V3
                    && r.buyDexType != DEX_UNISWAP_V2
                    ? r.buyDexType
                    : r.sellDexType);
        }
    }

    function _whitelistPrimaryRouters(PrimaryRouteConfig memory r) private {
        if (r.asset == address(0)) return;
        isRouterWhitelisted[r.buyRouter] = true;
        isRouterWhitelisted[r.sellRouter] = true;
        emit RouterWhitelistUpdated(r.buyRouter, true);
        emit RouterWhitelistUpdated(r.sellRouter, true);
    }

    // --------------------------------------------------------------------------------------------
    // Admin
    // --------------------------------------------------------------------------------------------

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address previous = operator;
        operator = newOperator;
        emit OperatorUpdated(previous, newOperator);
    }

    function setRouterWhitelist(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouterWhitelisted[router] = allowed;
        emit RouterWhitelistUpdated(router, allowed);
    }

    function setMaxTradeSize(address asset, uint256 maxAmount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        maxTradeSize[asset] = maxAmount;
        emit MaxTradeSizeUpdated(asset, maxAmount);
    }

    function setMaxGasPrice(uint256 newMaxGasPrice) external onlyOwner {
        maxGasPrice = newMaxGasPrice;
        emit MaxGasPriceUpdated(newMaxGasPrice);
    }

    /// @notice Operator (or owner) can stop execution.
    function pause() external onlyOperator {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Only the owner can resume execution.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Send an ERC20 balance to the owner.
    function withdraw(address token, uint256 amount) external nonReentrant onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        address to = owner();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Send ETH to the owner.
    function withdrawETH(uint256 amount) external nonReentrant onlyOwner {
        address to = owner();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(to, amount);
    }

    /// @notice Rescue stuck ERC20 dust/accidental transfers to an arbitrary recipient.
    function rescueTokens(address token, address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Rescue stuck ETH to an arbitrary recipient.
    function rescueETH(address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert EthTransferFailed();
        emit EthRescued(to, amount);
    }

    /// @dev Accept ETH refunds and forced transfers so the owner can rescue them.
    receive() external payable { }
}
