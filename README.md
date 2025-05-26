Swap2p
======

**Non-custodial P2P marketplace for swapping the native chain coin against fiat.  
Dual-side escrow. No timelocks, no on-chain arbitration — incentives drive settlement.**

---

## Table of Contents
1. [Why Swap2p?](#why-swap2p)
2. [How It Works](#how-it-works)
3. [Key Invariants](#key-invariants)
4. [Contract Layout](#contract-layout)
5. [Security Model & Caveats](#security-model--caveats)
6. [License](#license)

---

## Why Swap2p?
* **No custody** – coins stay in the contract until both parties agree.
* **Capital-efficient** – only `2 × amount` total collateral across both sides.
* **Partner revenue** – up to 20 % of protocol fees flow to affiliates.
* **Minimal bytecode** – single contract, optimized via-IR.

> The protocol intentionally has **no timelocks and no on-chain arbitrator**.  
> If either side stalls, they lose their collateral — simple game-theory, quick settlement.

---

## How It Works
| Step | BUY flow (maker buys coin) | SELL flow (maker sells coin) |
|------|---------------------------|------------------------------|
| ① Maker posts offer | min / max, price | same |
| ② Taker selects offer | pays `amount + 100 %` collateral | pays `100 %` collateral |
| ③ Maker accepts | pays `100 %` collateral | pays `amount + 100 %` collateral |
| ④ Fiat payer sends off-chain fiat | **maker** | **taker** |
| ⑤ Fiat receiver marks paid | maker | taker |
| ⑥ Fiat receiver releases escrow | **taker** | **maker** |
| ⑦ Contract: sends coin minus fee, returns both collaterals |

---

## Key Invariants
1. `ETH_out(maker) + ETH_out(taker) ≤ 3 × amount` for any deal.
2. A party cancelling after *ACCEPTED* forfeits **only** its collateral, never the principal.
3. Re-entrancy on `withdraw()` cannot double-spend `pending`.

---

## Contract Layout
| File | Purpose |
|------|---------|
| `src/Swap2p.sol` | Core logic: offers, dual escrow, fee split |
| `docs/` | Flow diagrams, audit notes |

---

## Security Model & Caveats
| Aspect | Design Choice |
|--------|---------------|
| Timelocks | **None** – deposits create urgency |
| Arbitration | **None** – dispute ⇒ staller loses collateral |
| Price oracle | Not required – price fixed at match time |
| Re-entrancy | Only `withdraw()` performs external call; state cleared first |
| Upgradability | Immutable bytecode (no proxy) |

If a user stalls after `ACCEPTED`, the counter-party cancels:
* `maker_cancelDeal` for **BUY** deals (maker pays fiat).
* `taker_cancelDeal` for **SELL** deals (taker pays fiat).  
  The staller’s collateral is slashed.

---

## License
Released under the MIT License – see [`LICENSE`](LICENSE).
