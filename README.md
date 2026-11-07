# JELLYSIUM Contracts

Pump-style token launchpad on Elysium (testnet now, mainnet 9 Nov 2026).

## Scope for audit

- `contracts/JellyPumpFactoryV6.sol` — JellyPumpFactoryV6 + JellyTokenV6 (459 lines).
  Deployed on Elysium Testnet (chain 99801) at
  `0x7115Ea2eD1aAF3046DB77dAB789BB02756dEEc88`, verified on the explorer.

## Build

- Solidity `0.8.20`, optimizer enabled, 200 runs.
- Dependencies are vendored under `contracts/openzeppelin/` (OpenZeppelin Contracts 5.0.2);
  see `remappings.txt` (`@openzeppelin/contracts/` -> `contracts/openzeppelin/`).

## What it does

Create and trade tokens on a bonding curve: limit orders, holder rewards,
buyback and burn, anti-snipe protection (60s window, 1% cap), graduation at
100 HYPE, creator fee 30% of the 2% trading fee (in HYPE).

Site: https://jellysium.vercel.app/ — X: @Jellysiumpad — Testnet only, no real funds.
