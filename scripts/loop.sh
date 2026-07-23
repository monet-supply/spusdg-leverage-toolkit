#!/usr/bin/env zsh
# Manual (no-flash-loan) lever-up to 10x on the spUSDG/USDG Morpho market, Robinhood Chain.
# Reference implementation: swap ETH->USDG (Uniswap v2), deposit to spUSDG, supply as
# collateral, then loop borrow->deposit->supply until ~10x (90% LTV vs 91.5% LLTV).
# NOTE: this takes ~20 iterations (~60 txs). The Looper contract does the same in ONE
# flash-loan tx and is the preferred path; this is kept for reference/transparency.
# Assumes ETH is already bridged to the wallet on Robinhood Chain.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
[[ -f "$SCRIPT_DIR/../.env" ]] && source "$SCRIPT_DIR/../.env"
: "${ROBINHOOD_RPC_URL:?set ROBINHOOD_RPC_URL in .env}"
: "${WALLET:?set WALLET in .env}"
: "${KEYSTORE:?set KEYSTORE in .env}"
: "${KEYSTORE_PASSWORD_FILE:?set KEYSTORE_PASSWORD_FILE in .env}"

RH="$ROBINHOOD_RPC_URL"
W="$WALLET"
ACC="--keystore $KEYSTORE --password-file $KEYSTORE_PASSWORD_FILE"

WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
SPUSDG=0xde770c84FE66E063336b31737cFE9790f18c4087
MORPHO=0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010
PAIR=0x8803c117ccae7B5146297876c2A25DF135141C4d           # Uni v2 WETH/USDG ; token0=WETH token1=USDG
ID=0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
MP="(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,0xde770c84FE66E063336b31737cFE9790f18c4087,0xe694c531F65c4BaBc88A52d7178476e095e51574,0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1,915000000000000000)"
MAXU=115792089237316195423570985008687907853269984665640564039457584007913129639935

SWAP_WEI="${SWAP_WEI:-5535000000000000}"   # ETH to swap into USDG seed (~$10 at ~$1807/ETH)

send(){ cast send --rpc-url "$RH" $=ACC "$@" >/dev/null; }
call(){ cast call --rpc-url "$RH" "$@"; }
num(){ grep -oE '^[0-9]+'; }
debt(){
  local bs tba tbs M
  bs=$(call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $W | sed -n 2p | num)
  M=$(call $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" $ID)
  tba=$(echo "$M" | sed -n 3p | num); tbs=$(echo "$M" | sed -n 4p | num)
  python3 -c "bs=$bs;tba=$tba;tbs=$tbs; print(0 if tbs==0 else -(-bs*tba//tbs))"
}
collUSDG(){
  local c; c=$(call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $W | sed -n 3p | num)
  call $SPUSDG "convertToAssets(uint256)(uint256)" $c | num
}

echo "### balances before"
echo "ETH: $(cast balance --rpc-url "$RH" $W --ether)"

echo "### 1) wrap $SWAP_WEI wei ETH -> WETH"
send $WETH "deposit()" --value $SWAP_WEI

echo "### 2) direct v2 swap WETH->USDG"
send $WETH "transfer(address,uint256)" $PAIR $SWAP_WEI
RES=$(call $PAIR "getReserves()(uint112,uint112,uint32)")
R0=$(echo "$RES" | sed -n 1p | grep -oE '^[0-9]+')   # WETH
R1=$(echo "$RES" | sed -n 2p | grep -oE '^[0-9]+')   # USDG
OUT=$(python3 -c "aI=$SWAP_WEI;r0=$R0;r1=$R1;o=(aI*997*r1)//(r0*1000+aI*997);print(int(o*0.99))")
echo "  reserves WETH=$R0 USDG=$R1 -> requesting USDG out=$OUT"
send $PAIR "swap(uint256,uint256,address,bytes)" 0 $OUT $W 0x
USDGBAL=$(call $USDG "balanceOf(address)(uint256)" $W | grep -oE '^[0-9]+')
echo "  USDG balance = $USDGBAL"

echo "### 3) approvals (USDG->spUSDG, spUSDG->Morpho)"
send $USDG "approve(address,uint256)" $SPUSDG $MAXU
send $SPUSDG "approve(address,uint256)" $MORPHO $MAXU

echo "### 4) deposit all USDG -> spUSDG, supply as collateral"
send $SPUSDG "deposit(uint256,address)" $USDGBAL $W
SP=$(call $SPUSDG "balanceOf(address)(uint256)" $W | grep -oE '^[0-9]+')
send $MORPHO "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" "$MP" $SP $W 0x

COLL=$(call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $W | sed -n 3p | num)
E=$(call $SPUSDG "convertToAssets(uint256)(uint256)" $COLL | num)
TARGET_DEBT=$(python3 -c "print(int($E*9))")   # 9x equity => 10x leverage, 90% LTV
echo "### equity(USDG)=$E  target_debt=$TARGET_DEBT"

echo "### 5) leverage loop"
for i in $(seq 1 30); do
  DEBT=$(debt); REM=$(python3 -c "print(max(0,$TARGET_DEBT-$DEBT))")
  [ "$REM" -le 100 ] && { echo "  reached target"; break; }
  CV=$(collUSDG)
  BORROW=$(python3 -c "cap=int($CV*0.915)-$DEBT; b=int(cap*0.99); print(max(0,min(b,$REM)))")
  [ "$BORROW" -le 100 ] && { echo "  no capacity left (i=$i)"; break; }
  send $MORPHO "borrow((address,address,address,address,uint256),uint256,uint256,address,address)" "$MP" $BORROW 0 $W $W
  UB=$(call $USDG "balanceOf(address)(uint256)" $W | num)
  send $SPUSDG "deposit(uint256,address)" $UB $W
  SP=$(call $SPUSDG "balanceOf(address)(uint256)" $W | num)
  send $MORPHO "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" "$MP" $SP $W 0x
  D2=$(debt); C2=$(collUSDG)
  echo "  loop $i: borrowed=$BORROW debt=$D2 collateralUSDG=$C2 LTV=$(python3 -c "print(round($D2/$C2*100,2))")%"
done

echo "### FINAL"
COLL=$(call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" $ID $W | sed -n 3p | num)
CV=$(collUSDG); DEBT=$(debt)
python3 -c "print(f'collateral: {$COLL/1e6:.4f} spUSDG = {$CV/1e6:.4f} USDG'); print(f'debt: {$DEBT/1e6:.4f} USDG'); print(f'LTV: {$DEBT/$CV*100:.2f}%  leverage: {$CV/($CV-$DEBT):.2f}x  (LLTV 91.5%)')"
echo "ETH left: $(cast balance --rpc-url "$RH" $W --ether)"
