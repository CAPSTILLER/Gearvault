# GearVault v2 — Control Terminal & Smart Contract

Official repository for **GearVault v2** deployed on Base mainnet.

## On-Chain Contract Addresses (Base)

| Role | Address | Description |
|---|---|---|
| **GearVault Contract** | [`0x41ca72e18f7f96f8f2b7be524ac8346e06bcb3ab`](https://basescan.org/address/0x41ca72e18f7f96f8f2b7be524ac8346e06bcb3ab#code) | Live Vault Contract on Base (Verified on BaseScan & Blockscout) |
| **GEAR Token** | `0x5880cD05605A549f1DAb01a53ca61Ee559244bD1` | Official GEAR ERC-20 (6 Decimals: `1 GEAR = 1_000_000`) |
| **Owner / Admin** | `0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca` | Ledger Cold Wallet (Two-step ownership, controls caps & pause) |
| **Initial Operator** | `0x785cBE4a9eE034f79d0dC45cab9C0365F225563E` | Hot Wallet for Caps Garage & Game Backends (Calls `dispense()`) |
| **Fee Treasury** | `0xCF1ac98565DA846E8263604b49C1276Ed78A0981` | Treasury Wallet receiving 90% of Gear NFT mint fees |

---

## What It Is

A secure vault contract on Base that holds GEAR tokens and allows authorized **operator** hot wallets (e.g. game backends, Vercel serverless functions, x402 endpoints) to pay out small reward amounts to players via `dispense()`.

- **Global Daily Cap:** 10,000 GEAR per UTC day (`10_000_000_000` base units).
- **Max Dispense Per Call:** 50 GEAR (`50_000_000` base units).
- **Per-Wallet Daily Cap:** Optional (defaults to 0 / off).
- **Two-Step Ownership Handover:** Typo-proof transfer (`transferOwnership` + `acceptOwnership`).
- **Emergency Circuit Breaker:** Admin toggle to freeze all dispensing instantly (`setPaused(true)`).

---

## App: Gear Vault Control Terminal

- **Live Bankr App:** [Gear Vault Control Terminal](https://bankr.bot/apps/gear-vault-control)
- **Features:**
  1. Live telemetry & reserve tracking.
  2. Multi-operator authorization and revocation.
  3. Caps & limits configuration.
  4. Circuit breaker & emergency fund recovery (`withdrawGear`, `rescueToken`).
  5. Two-step ownership handover controls.
  6. 1-click dev snippets for Node.js/Viem and full ABI JSON.

---

## Integrating `dispense()` in Game Backends (Vercel / x402 / Node.js)

```typescript
import { createWalletClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

const account = privateKeyToAccount(process.env.OPERATOR_PRIVATE_KEY as `0x${string}`);
const client = createWalletClient({
  account,
  chain: base,
  transport: http(process.env.BASE_RPC_URL)
});

const VAULT_ADDRESS = '0x41ca72e18f7f96f8f2b7be524ac8346e06bcb3ab';
const abi = parseAbi([
  'function dispense(address recipient, uint256 amount) external'
]);

export async function payPlayer(playerAddress: `0x${string}`, gearAmount: number) {
  // 1 GEAR = 1_000_000 base units (6 decimals)
  const units = BigInt(Math.round(gearAmount * 1_000_000));
  const txHash = await client.writeContract({
    address: VAULT_ADDRESS,
    abi,
    functionName: 'dispense',
    args: [playerAddress, units]
  });
  return txHash;
}
```
