# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Submodule: StableYieldAccumulator

This is a Foundry smart contract submodule for the StableYieldAccumulator contract.

## Purpose and Architecture

### Problem Statement

In the Phoenix architecture, multiple yield strategies exist, each corresponding to a different stablecoin. Phlimbo distributes these rewards, but as yield strategies grow in number, this becomes unwieldy and gas-intensive. Additionally, Limbo stakers would need to manage many different reward tokens.

### Solution

StableYieldAccumulator consolidates all yield strategy rewards into a single stablecoin before Phlimbo distribution. This provides:

1. **Simplified rewards** - Limbo stakers only deal with 2 tokens: phUSD and one stablecoin
2. **Future-proof Phlimbo** - No upgrades/migrations needed when yield strategies change
3. **Decentralized conversion** - External actors perform the token swaps, not the protocol

### How It Works

1. **Yield Strategy Registry** - Maintains a dynamic list of yield strategies
2. **Exchange Rate Mappings** - Tracks decimal places (6 for USDC, 18 for Dola, etc.) and exchange rates
3. **No Oracles/AMMs** - Uses assumed 1:1 exchange rates for stablecoins (owner can adjust for permanent depegs)
4. **Claim Mechanism** - External users swap their reward token holdings for pending yield strategy rewards

### Claim Example

Assumptions:
- Reward token: USDC
- Yield Strategy A: 10 USDT pending
- Yield Strategy B: 5 USDS pending
- Exchange rates: 1:1
- Discount rate: 2%

Process:
1. Total pending = 15 USD equivalent
2. With 2% discount, claimer pays: 15 * 0.98 = 14.7 USDC
3. Claimer receives: 10 USDT + 5 USDS
4. Phlimbo receives: 14.7 USDC for distribution

The discount incentivizes external actors to pay gas costs for the conversion.

### Key Components

1. **Yield Strategy List** - Dynamic, owner-managed list of yield strategies
2. **Token Config Mapping** - Per-token: decimals, exchange rate, paused status
3. **Global Discount Rate** - Incentive for claimers (e.g., 2%)
4. **Owner Controls**:
   - Add/remove yield strategies
   - Update exchange rates (for permanent depegs)
   - Pause tokens (for black swan events)
   - Set discount rate

## Dependency Management

Dependencies are managed as regular git submodules under `lib/` (see `.gitmodules`):

- External libraries (`openzeppelin-contracts`, `forge-std`) and sibling
  contracts (`vault`, `pauser`, `phlimbo-ea`, `yield-claim-nft`) are all plain
  submodules with full source available.
- Update with `git submodule update --remote <path>`; add with
  `git submodule add <url> lib/<name>`.
- Import paths are wired through `remappings.txt`.

## Project Structure

- `src/` - Solidity source files
- `test/` - Test files (TDD required)
- `script/` - Deployment scripts
- `lib/` - Dependencies as git submodules (vault, pauser, phlimbo-ea, yield-claim-nft, openzeppelin-contracts, forge-std)

## Development Guidelines

### Test-Driven Development (TDD)

**ALL** features, bug fixes, and modifications MUST follow TDD principles:

1. **Write tests first** - Before implementing any feature
2. **Red phase** - Write failing tests that define the expected behavior
3. **Green phase** - Write minimal code to make tests pass
4. **Refactor phase** - Improve code while keeping tests green

### Testing Commands

- `forge test` - Run all tests
- `forge test -vvv` - Run tests with verbose output
- `forge test --match-contract <ContractName>` - Run specific contract tests
- `forge test --match-test <testName>` - Run specific test
- `forge coverage` - Check test coverage

### Other Commands

- `forge build` - Compile contracts
- `forge fmt` - Format Solidity code
- `forge snapshot` - Generate gas snapshots

## ClaimArbitrage Reward Token Accounting

### Why the Reward Token Gets Special Treatment in Step 5

ClaimArbitrage's Step 5 iterates `knownStables[]` to convert each received stablecoin into USDC via a Uniswap V4 swap. However, when SYA's reward token (currently USDC) is itself a strategy token -- meaning a yield strategy distributes USDC -- the contract must skip the swap for that token. Swapping USDC to USDC is nonsensical (no self-referential pool exists), and the deposit into PoolManager alone already creates the correct positive delta. The reward token is already the target denomination, so no conversion is needed.

### Delta Accounting Flow

The flash-borrowed token for the price pump is sUSDS (not USDC). USDC is `take()`-n from PoolManager in Step 2 to pay for the SYA `claim()` call. After claim(), ClaimArbitrage's real USDC balance is:

```
usdcBorrowed - phlimboPayment + usdcFromStrategies
```

Depositing all of this back into PoolManager (via `_depositIntoPM`) creates a positive USDC delta. Combined with the negative delta from Step 2 and positive deltas from converting other stables to USDC, the net USDC delta equals the arbitrage profit. Step 7 then swaps this net USDC delta to WETH for profit extraction.

### The One-Directional Invariant (Audit M-01)

SYA's registered strategy tokens must be a subset of ClaimArbitrage's `knownStables[]`. The reverse is not required -- `knownStables[]` CAN contain tokens that SYA does not currently distribute (preemptive registration is fine). This invariant is enforced by `_validateKnownStablesCoverage()` which runs at the start of every `unlockCallback()`. If violated, the entire atomic operation reverts, preventing tokens from being silently locked in the contract.

### Why `sya.rewardToken()` Is Used Dynamically

Step 5 queries `sya.rewardToken()` to determine which token to skip, rather than using ClaimArbitrage's immutable `USDC` address. The reward token is conceptually a property of SYA, not of ClaimArbitrage. If SYA's reward token were ever reconfigured, ClaimArbitrage's logic must adapt automatically without redeployment. The immutable `USDC` in ClaimArbitrage represents what CA was initialized with; `sya.rewardToken()` represents what SYA currently expects.

## Important Reminders

- Dependencies are consumed as regular git submodules in `lib/`
- Follow Solidity best practices and naming conventions
- Use Foundry testing tools exclusively (no Hardhat or Truffle)
