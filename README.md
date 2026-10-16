# SqueekChain (SQK)

A plain, fixed-supply ERC-20 token for an IMD custom token launch on Ethereum mainnet.

| Parameter | Value |
|---|---|
| Solidity contract (manifest `token.contract`) | `SqueekChainToken` |
| `name()` | `SqueekChain` |
| `symbol()` | `SQK` |
| `decimals()` | `18` |
| Total supply (whole tokens) | 1,000,000,000 |
| Total supply (minor units, manifest `token.totalSupply`) | `1000000000000000000000000000` (1e27) |
| Constructor arguments (manifest `constructorArgs`) | none (`[]`) |
| Application contracts | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, EVM `cancun` |

The whole supply is minted exactly once, in the constructor, to `msg.sender`. Nothing can mint
afterwards. There is no owner, no role, no pause, no blocklist, no freeze, no seize, no fee or tax
on transfer, no burn function, no external call, no `delegatecall`, no `selfdestruct`, and no
proxy or upgrade path. The token is OpenZeppelin v5.1.0 `ERC20` with a constructor and a handful
of public constants, and nothing else.

## Layout

```
foundry.toml                         compiler pins and build settings (see comments inside)
remappings.txt                       forge-std/ and @openzeppelin/contracts/ remappings
src/SqueekChainToken.sol             the token
script/DeploySqueekChain.s.sol       dev/fork deploy script (not used for the launch)
test/SqueekChainToken.t.sol          unit and fuzz tests
test/SqueekChainToken.invariant.t.sol invariant tests (supply fixed, balances sum to supply)
lib/forge-std/                       vendored forge-std v1.9.7 (src + licences, no git metadata)
lib/openzeppelin-contracts/          vendored OpenZeppelin Contracts v5.1.0 (`contracts/` + licence)
```

Dependencies are vendored as ordinary files, not git submodules, so the project builds and tests
with no network. The directory `lib/oz-tmp/` is an empty leftover of the OpenZeppelin clone that the
build sandbox would not let be deleted (it pins any `.gitmodules` file read-only). It is listed in
`.gitignore`, contains nothing the project uses, and is not a submodule.

## Build and test

```
forge build
forge test
forge fmt --check
```

The verifier runs the fuzz tests with a fixed seed; to reproduce locally:

```
FOUNDRY_FUZZ_SEED=0x9b9953672e63ee902bd53e431f6ecb1fda8f6a11ea89a4a60e8e26a5bee8781b forge test
```

Tests read no environment variables, do not depend on the calling address, and pass in any order
and in parallel.

### What the tests cover

Success paths:

- name, symbol, decimals and the supply constants agree with the table above;
- the constructor mints the whole supply once, to `msg.sender` (not `tx.origin`), emitting a single
  `Transfer(0, deployer, supply)`;
- each deployment mints to its own deployer, including deployment through CREATE2 with no arguments,
  which is how the factory deploys it;
- `transfer`, `approve`, `transferFrom` move exactly what they say, decrement finite allowances,
  leave infinite allowances alone, and emit the standard events;
- the launch flows (factory to distributor to claimant, factory to pool) arrive whole;
- fuzzed transfers and chained transfers conserve the supply;
- an invariant suite drives random transfers, approvals and `transferFrom` calls among five actors and
  checks after every call that `totalSupply()` is unchanged and that balances sum to it;
- the deploy script's `deploy()` function returns a token whose supply belongs to its caller.

Failure paths:

- transfers above balance (by one wei and fuzzed) revert with `ERC20InsufficientBalance`;
- `transferFrom` without, or above, an allowance reverts with `ERC20InsufficientAllowance`, and
  above the owner's balance with `ERC20InsufficientBalance` even when allowed;
- transfers and `transferFrom` to the zero address revert with `ERC20InvalidReceiver`;
- approving the zero address reverts with `ERC20InvalidSpender`;
- the deployer cannot pull a holder's tokens without an allowance;
- none of the common mint, ownership, upgrade, pause, blocklist, freeze, lock, burn or seize
  selectors exist: every one reverts for both a stranger and the deployer, the supply does not
  change, and a holder can still transfer afterwards;
- the token does not accept ether;
- the runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and is under the
  EIP-170 limit.

## Launch parameters

These are the launch's, decided by IMD's policy and the requester's paid terms. They are recorded
here for the reader; the manifest step writes `launch.json` after this work is accepted, and this
repository deliberately contains no `launch.json`.

| Setting | Value |
|---|---|
| Chain | Ethereum mainnet (chain id 1) |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | 12500 (1.25%, the launch policy's fee) |
| Tick spacing | 60 |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics.poolBps` | 8000 (80% of the supply seeds the single-sided pool) |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD for the whole supply) |
| `economics.remainderTo` | `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823` |
| Swarm share | 10%, taken by the factory and sent to the launch's MerkleDistributor |

How the supply moves at launch, all of it through plain `transfer` calls on this token:

1. The factory deploys `SqueekChainToken` (CREATE2, salt = launch number). The constructor mints
   1e27 SQK to the factory.
2. The factory sends 10% to the MerkleDistributor for the contributor swarm.
3. The factory seeds 80% into the IMD/SQK Uniswap v4 pool at the price derived from the 2,500 IMD cap.
4. The factory sends the remaining 10% to `economics.remainderTo`.

Because the token has no fee, tax, burn, hook or exemption logic, every one of these flows moves
exactly the amount requested, and the token needs no knowledge of the factory, pool manager or
distributor addresses. That is why the constructor takes no arguments.

## Assumptions

- "The deployer" in the brief is the constructor's `msg.sender`. At launch that is IMD's
  ProjectFactory, which pays the supply out as described above. In the dev script it is the
  broadcast sender; in tests it is a pranked address.
- The brief asks for a token with a name, symbol and fixed supply and nothing more, so no owner,
  burn, permit (ERC-2612), votes, pause or tax feature was added. Adding any of them later would need a
  new launch, since the token is immutable.
- 18 decimals is the ERC-20 default and matches the paired currency IMD, so no decimal
  normalisation is involved anywhere in the launch flows.
- Holders can still destroy their own tokens by sending them to an address nobody controls. The
  supply reported by `totalSupply()` does not shrink when they do, since there is no `burn`.
- The contract's Solidity name `SqueekChainToken` (16 characters) is what the manifest records; it
  is distinct from the token name `SqueekChain` and symbol `SQK`.

## After launch

There is nothing to configure. The token has no owner-settable value, no setter and no admin, so
there is no "After launch" setting for the requester to fill in.

## Operational responsibilities

- **The requester** holds whatever arrives at `economics.remainderTo` (10% of the supply) and is
  responsible for the custody of that address. No one, including IMD, can move, freeze or recover
  those tokens if the key is lost or compromised.
- **The requester** should verify the source on Etherscan after the launch
  (`forge verify-contract` with the settings in `foundry.toml`: solc 0.8.26, optimizer 200 runs,
  `bytecode_hash = none`, EVM cancun), so holders can read the code. This step belongs to whoever
  holds the deployed address and an explorer API key; this job did not deploy anything.
- **IMD's deployer** performs the launch through the factory from the attested bytecode and
  derives the pool's opening price. This repository signs nothing and holds no keys.
- **Nobody** has an operational lever over the token after deployment. There is no pause to pull,
  no blocklist to maintain, no upgrade to schedule, and no mint to guard. Incident response is
  limited to communication; the contract itself cannot be changed.
- **Liquidity** after the seed is governed by the Uniswap v4 pool, not by this contract. Anyone may
  add or remove their own liquidity under Uniswap's rules.

## Security notes

The `eth-security` checklist was applied to the token:

- Access control: there are no privileged functions, so nothing is unprotected.
- Reentrancy: the token makes no external calls.
- Decimals: 18, same as the paired currency.
- Integer math: the only arithmetic is OpenZeppelin's balance accounting under Solidity 0.8 checks.
- Input validation: zero receivers and zero spenders revert (OpenZeppelin v5 behaviour); zero
  amounts are allowed, as the ERC-20 standard requires.
- Events: every state change emits the standard `Transfer` or `Approval` event.
- No approvals are granted by the contract itself; infinite approvals are a holder's own choice.
- No proxy, delegatecall, selfdestruct or signatures are used.
- Tools run: `forge build`, `forge test` (unit, fuzz with the verifier's seed, invariant), and the
  bytecode opcode scan inside the test suite. Slither and Mythril were not available in this
  environment and did not run.

Tests passing are not an audit. For a contract this small built on OpenZeppelin's audited `ERC20`,
the remaining risk sits in the launch flow and the pool, which IMD's protected floor tests exercise
against the attested bytecode before admission.

## Deploy script

`script/DeploySqueekChain.s.sol` is for local forks and rehearsals only; the production launch is
IMD's. It reads no environment variables. `deploy()` is the function tests call; `run()` wraps it in
a broadcast whose sender comes from the forge CLI:

```
forge script script/DeploySqueekChain.s.sol --rpc-url <fork> --broadcast --private-key <dev key>
```

The broadcast sender receives the whole supply.
