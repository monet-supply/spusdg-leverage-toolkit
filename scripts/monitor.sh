#!/bin/zsh
# Hourly spUSDG/USDG (Robinhood Chain) leverage-position monitor.
# - records RoE to roe.log every run
# - if RoE < spUSDG base yield  -> unwind to 1x (repay all debt, keep collateral)
# - if at 1x AND RoE(10x) > 2*base yield -> relever to 10x
# Uses the on-chain Looper flash-loan helper (atomic; reverts harmlessly if mis-sized).
# NO LLM/model in the loop — pure deterministic shell + cast + python3.

export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="${0:A:h}"
[[ -f "$SCRIPT_DIR/../.env" ]] && source "$SCRIPT_DIR/../.env"
: "${ROBINHOOD_RPC_URL:?set ROBINHOOD_RPC_URL in .env}"
: "${WALLET:?set WALLET in .env}"
: "${LOOPER:?set LOOPER in .env}"
: "${KEYSTORE:?set KEYSTORE in .env}"
: "${KEYSTORE_PASSWORD_FILE:?set KEYSTORE_PASSWORD_FILE in .env}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR}"
mkdir -p "$LOG_DIR"

LOG=$LOG_DIR/roe.log
LOCK=$LOG_DIR/.lock
PW=$KEYSTORE_PASSWORD_FILE
KS=$KEYSTORE
RH="$ROBINHOOD_RPC_URL"
W="$WALLET"

# --- single-instance lock (portable; macOS has no flock) ---
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# public protocol/market addresses (Robinhood Chain, chain id 4663)
MORPHO=0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010
SPUSDG=0xde770c84FE66E063336b31737cFE9790f18c4087
IRM=0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1
ID=0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
MP="(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,0xde770c84FE66E063336b31737cFE9790f18c4087,0xe694c531F65c4BaBc88A52d7178476e095e51574,0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1,915000000000000000)"

num(){ grep -oE '^[0-9]+' | head -1; }
CALL(){ cast call --rpc-url "$RH" "$@" 2>/dev/null; }
SEND(){ cast send --rpc-url "$RH" --keystore "$KS" --password-file "$PW" "$@" >/dev/null 2>>"$LOG_DIR/cron.err"; }
TS(){ date -u +%Y-%m-%dT%H:%M:%SZ; }

read_state(){   # sets globals CV DEBT COLL RATE_PS VSR
  local POS BS M TBA TBS TSA TSS LU FEE
  POS=$(CALL $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $W)
  BS=$(echo "$POS"|sed -n 2p|num); COLL=$(echo "$POS"|sed -n 3p|num)
  M=$(CALL $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" $ID)
  TSA=$(echo "$M"|sed -n 1p|num); TSS=$(echo "$M"|sed -n 2p|num)
  TBA=$(echo "$M"|sed -n 3p|num); TBS=$(echo "$M"|sed -n 4p|num)
  LU=$(echo "$M"|sed -n 5p|num);  FEE=$(echo "$M"|sed -n 6p|num)
  CV=$(CALL $SPUSDG "convertToAssets(uint256)(uint256)" $COLL|num)
  DEBT=$(python3 -c "print(0 if $TBS==0 else -(-$BS*$TBA//$TBS))")
  RATE_PS=$(CALL $IRM "borrowRateView((address,address,address,address,uint256),(uint128,uint128,uint128,uint128,uint128,uint128))(uint256)" "$MP" "($TSA,$TSS,$TBA,$TBS,$LU,$FEE)"|num)
  VSR=$(CALL $SPUSDG "vsr()(uint256)"|num)
}

read_state
[[ -z "$CV" || -z "$DEBT" || -z "$RATE_PS" || -z "$VSR" ]] && { echo "$(TS) ERROR read failed" >> "$LOG"; exit 1; }

# compute metrics + decision
DEC=$(python3 -c "
SPY=365*24*3600
y=($VSR/1e27)**SPY-1
r=2.718281828459045**($RATE_PS/1e18*SPY)-1
cv=$CV; d=$DEBT; e=cv-d
L=cv/e if e>0 else 0
roe = L*y-(L-1)*r
roe10 = 10*y-9*r
if L>1.001 and roe < y:      act=1
elif abs(L-1)<0.01 and roe10 > 2*y:  act=10
else:                        act=0
print(f'{y*100:.4f}|{r*100:.4f}|{L:.4f}|{roe*100:.4f}|{roe10*100:.4f}|{act}')
")
IFS='|' read Y R L ROE ROE10 ACT <<< "$DEC"

[[ ! -f "$LOG" ]] && echo "timestamp,leverage_x,spusdg_yield_%,borrow_rate_%,roe_%,roe_10x_%,collateral_usdg,debt_usdg,action" >> "$LOG"

act_note="none"
if [[ "$ACT" == "1" ]]; then
  act_note="UNWIND->1x (RoE ${ROE}% < yield ${Y}%)"
  echo "$(TS) ACTION $act_note" >> "$LOG_DIR/cron.err"
  read_state
  REPAY=$DEBT
  if [[ "$REPAY" -gt 0 ]]; then
    WC=$(python3 -c "print($(CALL $SPUSDG 'previewWithdraw(uint256)(uint256)' $REPAY|num)+2000)")
    SEND $MORPHO "setAuthorization(address,bool)" $LOOPER true
    SEND $LOOPER "deleverage(uint256,uint256)" $REPAY $WC
    SEND $MORPHO "setAuthorization(address,bool)" $LOOPER false
  fi
elif [[ "$ACT" == "10" ]]; then
  act_note="RELEVER->10x (RoE10 ${ROE10}% > 2x yield)"
  echo "$(TS) ACTION $act_note" >> "$LOG_DIR/cron.err"
  read_state
  FLASH=$(python3 -c "print(int(10*($CV-$DEBT)-$CV))")
  MAX=$(python3 -c "print(int((0.915*$CV-$DEBT)/0.085))")
  if [[ "$FLASH" -gt 0 && "$FLASH" -lt "$MAX" ]]; then
    SEND $MORPHO "setAuthorization(address,bool)" $LOOPER true
    SEND $LOOPER "leverage(uint256)" $FLASH
    SEND $MORPHO "setAuthorization(address,bool)" $LOOPER false
  else
    act_note="RELEVER-SKIPPED (flash=$FLASH max=$MAX)"
  fi
fi

echo "$(TS),$L,$Y,$R,$ROE,$ROE10,$(python3 -c "print(f'{$CV/1e6:.4f}')"),$(python3 -c "print(f'{$DEBT/1e6:.4f}')"),$act_note" >> "$LOG"
