# spUSDG/USDG Leverage Toolkit — Robinhood Chain

Tooling for running a leveraged **spUSDG collateral / USDG debt** carry position on the
[Morpho](https://morpho.org) market on **Robinhood Chain** (Arbitrum Orbit L2, chain id `4663`).
Includes an atomic flash-loan lever/delever helper contract and an autonomous hourly
rebalancing monitor.

> ⚠️ **Risk / disclaimer.** This runs **real leverage** (up to ~10x, i.e. ~90% LTV against a
> 91.5% liquidation threshold — a thin buffer). Leverage can be liquidated; rates and the
> spUSDG↔USDG relationship can move against you. The contracts here are **unaudited**. This is
> not financial advice. Use at your own risk, and only with funds you can afford to lose.

## What's here

| Path | What |
|---|---|
| `src/Looper.sol` | Atomic flash-loan **lever + delever** helper. `leverage(flashAmt)` and `deleverage(repayAssets, withdrawColl)`. Owner-gated; reverts harmlessly if mis-sized. |
| `src/Deleverager.sol` | Delever-only precursor to `Looper` (kept for reference). |
| `scripts/monitor.sh` | Hourly monitor: logs RoE, and rebalances via the Looper per the rules below. Pure shell + `cast` + `python3` — **no LLM in the loop**. |
| `scripts/loop.sh` | Manual (no-flash-loan) lever-up to 10x. Reference only; the Looper does the same in one tx. |
| `launchd/*.plist.example` | macOS LaunchAgent to run the monitor hourly (survives sleep/wake, unlike cron). |

## Strategy / rebalance rules

With `y` = spUSDG base yield (its `vsr`), `r` = USDG Morpho borrow rate, `L` = leverage:

- **RoE(L) = L·y − (L−1)·r**
- Unwind to **1x** (repay all debt, keep collateral) when `RoE < y` — i.e. carry turns negative (`r > y`).
- Relever **1x → 10x** when `RoE(10x) > 2y` — i.e. `r < 0.889·y`.
- In between it holds (hysteresis, so it won't flip-flop hourly).

## Public addresses (Robinhood Chain, 4663)

| | |
|---|---|
| Morpho Blue | `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` |
| USDG (loan, 6-dec) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| spUSDG (collateral, ERC4626, 6-dec) | `0xde770c84FE66E063336b31737cFE9790f18c4087` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Market oracle | `0xe694c531F65c4BaBc88A52d7178476e095e51574` |
| Market IRM | `0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1` |
| Market id (LLTV 91.5%) | `0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114` |
| Uniswap v2 WETH/USDG pair | `0x8803c117ccae7B5146297876c2A25DF135141C4d` |
| L1 (Ethereum) bridge Delayed Inbox | `0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D` |

## Setup

Requires [Foundry](https://getfoundry.sh) (`forge`, `cast`), `python3`, and a funded keystore.

```sh
cp .env.example .env        # then fill in — .env is gitignored, never commit it
forge build

# 1. deploy your Looper (signs from your keystore)
forge create src/Looper.sol:Looper \
  --rpc-url "$ROBINHOOD_RPC_URL" --keystore "$KEYSTORE" --password-file "$KEYSTORE_PASSWORD_FILE" --broadcast
# put the deployed address in .env as LOOPER=

# 2. run the monitor once to sanity-check (logs, no action unless a rule triggers)
./scripts/monitor.sh && cat scripts/roe.log

# 3. install the hourly LaunchAgent
cp launchd/com.example.spusdg-monitor.plist.example ~/Library/LaunchAgents/com.example.spusdg-monitor.plist
#    edit ABSOLUTE_PATH_TO_REPO inside it, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.spusdg-monitor.plist
```

The monitor authorizes the Looper (`Morpho.setAuthorization`), acts, and revokes each time it
rebalances. Kill switch: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.example.spusdg-monitor.plist`.

## Security notes

- **Secrets live in `.env`** (gitignored): the RPC URL (embeds your Alchemy key), wallet address,
  and keystore/password paths. Keep the keystore and password file **outside** the repo.
- The signer is a hot keystore driving an unattended job — fund the wallet with only what the
  strategy needs, and treat it as low-value / disposable.
- Contracts are unaudited; the flash-loan paths are atomic (a mis-size reverts with no state
  change), but that is not a substitute for an audit.

## License

MIT
