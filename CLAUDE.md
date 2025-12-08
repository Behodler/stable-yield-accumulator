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

### Types of Dependencies

1. **Immutable Dependencies** (lib/immutable/)
   - External libraries and contracts that don't change based on sibling requirements
   - Full source code is available
   - Examples: OpenZeppelin, standard libraries

2. **Mutable Dependencies** (lib/mutable/)
   - Dependencies from sibling submodules
   - ONLY interfaces and abstract contracts are exposed
   - NO implementation details are available
   - Changes to these dependencies must go through the change request process

### Important Rules

- **NEVER** access implementation details of mutable dependencies
- Mutable dependencies only expose interfaces and abstract contracts
- If a feature requires changes to a mutable dependency, add it to the change request queue
- All development must follow Test-Driven Development (TDD) principles using Foundry

### Change Request Process

When a feature requires changes to a mutable dependency:

1. Add the request to `MutableChangeRequests.json` with format:
   ```json
   {
     "requests": [
       {
         "dependency": "dependency-name",
         "changes": [
           {
             "fileName": "ISomeInterface.sol",
             "description": "Plain language description of what needs to change"
           }
         ]
       }
     ]
   }
   ```

2. **STOP WORK** immediately after adding the change request
3. Inform the user that dependency changes are needed
4. Wait for the dependency to be updated before continuing

### Available Commands

Use these as slash commands (e.g., `/add-mutable-dependency`) or run the scripts directly:

- `.claude/scripts/add-mutable-dependency.sh <repo>` - Add a mutable dependency (sibling)
- `.claude/scripts/add-immutable-dependency.sh <repo>` - Add an immutable dependency
- `.claude/scripts/update-mutable-dependency.sh <name>` - Update a mutable dependency
- `.claude/scripts/consider-change-requests.sh` - Review and implement sibling change requests

## Project Structure

- `src/` - Solidity source files
- `test/` - Test files (TDD required)
- `script/` - Deployment scripts
- `lib/mutable/` - Mutable dependencies (interfaces only)
- `lib/immutable/` - Immutable dependencies (full source)

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

## Important Reminders

- This submodule operates independently from sibling submodules
- Follow Solidity best practices and naming conventions
- Use Foundry testing tools exclusively (no Hardhat or Truffle)
- If you need to change a mutable dependency, use the change request process
