// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IMorpho {
    struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
    function repay(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data) external returns (uint256, uint256);
    function withdrawCollateral(MarketParams memory m, uint256 assets, address onBehalf, address receiver) external;
}
interface IERC20 { function approve(address,uint256) external returns (bool); function transfer(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IVault { function redeem(uint256 shares, address receiver, address owner) external returns (uint256); }

/// One-shot flash-loan deleverager for the spUSDG/USDG Morpho market on Robinhood Chain.
/// Delever-only precursor to Looper.sol, kept for reference.
/// Atomic: repay USDG debt -> withdraw freed spUSDG collateral -> redeem to USDG -> repay flash loan.
/// If anything is mis-sized the whole tx reverts and the position is untouched.
contract Deleverager {
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address  constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address  constant SPUSDG = 0xde770c84FE66E063336b31737cFE9790f18c4087;
    address public immutable owner;
    IMorpho.MarketParams mp;

    constructor() {
        owner = msg.sender;
        mp = IMorpho.MarketParams(USDG, SPUSDG, 0xe694c531F65c4BaBc88A52d7178476e095e51574, 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1, 915000000000000000);
    }

    /// @param repayAssets     USDG debt to repay (== flash loan size)
    /// @param withdrawColl    spUSDG collateral to withdraw (>= amount that redeems to repayAssets)
    function deleverage(uint256 repayAssets, uint256 withdrawColl) external {
        require(msg.sender == owner, "not owner");
        MORPHO.flashLoan(USDG, repayAssets, abi.encode(repayAssets, withdrawColl));
        uint256 u = IERC20(USDG).balanceOf(address(this));
        if (u > 0) IERC20(USDG).transfer(owner, u);
        uint256 s = IERC20(SPUSDG).balanceOf(address(this));
        if (s > 0) IERC20(SPUSDG).transfer(owner, s);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(MORPHO), "not morpho");
        (uint256 repayAssets, uint256 withdrawColl) = abi.decode(data, (uint256, uint256));
        IERC20(USDG).approve(address(MORPHO), repayAssets);
        MORPHO.repay(mp, repayAssets, 0, owner, "");
        MORPHO.withdrawCollateral(mp, withdrawColl, owner, address(this));
        IVault(SPUSDG).redeem(withdrawColl, address(this), address(this));
        IERC20(USDG).approve(address(MORPHO), assets);
    }
}
