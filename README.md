# miniera_sc

Smart-contract suite for the Miniera Protocol, built with Foundry.

## Contracts
- `src/BoardManager.sol`: Round lifecycle, deposits, and reward distribution.
- `src/Minter.sol`: Pricing and minting logic for MINB.
- `src/Vault.sol`: Collateral custody and payout flow.
- `src/Referral.sol`: Referral credit accounting.
- `src/Automation.sol`: Helper flows for automated participation.
- `src/Token.sol`: ERC20 token implementation.
- `src/Airdrop.sol`: Airdrop payout vault.

## Scripts
- `script/Deploy.s.sol`: Deployment entrypoint (uses env vars).

## Tests
Foundry tests live in `test/`.

Run:
```sh
forge test
```

## Environment
See `.env.example` for the required variables.

## License
Apache-2.0 (see `LICENSE`).
