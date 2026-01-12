// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IErrors} from "../../interfaces/IErrors.sol";
import {IStrataCDO} from "../../interfaces/IStrataCDO.sol";
import {IERC20Cooldown} from "../../interfaces/cooldown/ICooldown.sol";
import {IDistributor} from "../../interfaces/IDistributor.sol";
import {ISwapContract} from "../../interfaces/ISwapContract.sol";
import {Strategy} from "../../Strategy.sol";

contract SteakhouseUSDC is Strategy {
    IERC4626 public immutable steakhouseUSD;
    IERC20 public immutable USDC;

    IERC20Cooldown public erc20Cooldown;

    /// @notice Merkl distributor contract for claiming rewards
    IDistributor public distributor;

    /// @notice SwapContract for swapping rewards to USDC
    ISwapContract public swapContract;

    /**
     * configuration
     */
    uint256 public steakhouseUSDCooldownJrt;
    uint256 public steakhouseUSDCooldownSrt;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event RewardsClaimed(address indexed rewardToken, uint256 rewardAmount, uint256 usdcReceived);
    event DistributorUpdated(address indexed distributor);
    event SwapContractUpdated(address indexed swapContract);

    constructor(IERC4626 steakhouseUSD_) {
        steakhouseUSD = steakhouseUSD_;
        USDC = IERC20(steakhouseUSD_.asset());
    }

    function initialize(address owner_, address acm_, IStrataCDO cdo_, IERC20Cooldown erc20Cooldown_)
        public
        virtual
        initializer
    {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;

        SafeERC20.forceApprove(steakhouseUSD, address(erc20Cooldown), type(uint256).max);
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      If the deposited token is USDC, it will be deposited to receive steakhouseUSD shares.
     *      If the deposited token is already steakhouseUSD shares, it will be accepted as is.
     * @param tranche The address of the tranche depositing assets (not used in this strategy)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for steakhouseUSD deposits)
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit(address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner)
        external
        onlyCDO
        returns (uint256)
    {
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(USDC)) {
            SafeERC20.forceApprove(USDC, address(steakhouseUSD), tokenAmount);
            steakhouseUSD.deposit(tokenAmount, address(this));
            return tokenAmount;
        }
        if (token == address(steakhouseUSD)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     *      If withdrawing steakhouseUSD shares, a cooldown period is applied based on the tranche type.
     *      If withdrawing USDC, the steakhouseUSD shares are redeemed directly (no cooldown mechanism).
     *      An overloaded version accepts a shouldSkipCooldown parameter to skip the cooldown for steakhouseUSD withdrawals.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn
     * @param tokenAmount The amount of tokens to be withdrawn (not used in this implementation)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn (shares for steakhouseUSD, baseAssets for USDC)
     */
    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, false);
    }

    function withdraw(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) external onlyCDO returns (uint256) {
        return withdrawInner(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
    }

    function withdrawInner(
        address tranche,
        address token,
        uint256 tokenAmount,
        uint256 baseAssets,
        address sender,
        address receiver,
        bool shouldSkipCooldown
    ) internal returns (uint256) {
        uint256 shares = steakhouseUSD.previewWithdraw(baseAssets);
        if (token == address(steakhouseUSD)) {
            uint256 cooldownSeconds =
                shouldSkipCooldown ? 0 : (cdo.isJrt(tranche) ? steakhouseUSDCooldownJrt : steakhouseUSDCooldownSrt);
            erc20Cooldown.transfer(steakhouseUSD, sender, receiver, shares, cooldownSeconds);
            return shares;
        }
        if (token == address(USDC)) {
            // Morpho allows direct withdrawal - no cooldown needed
            steakhouseUSD.withdraw(baseAssets, receiver, address(this));
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev This function is part of the reserve reduction process and can only be called by the CDO.
     *      It handles both steakhouseUSD shares and USDC tokens, applying different transfer mechanisms for each.
     *      For steakhouseUSD shares, it uses erc20Cooldown with no cooldown period.
     *      For USDC, it withdraws directly from the Morpho vault.
     * @param token The address of the token to be withdrawn (either steakhouseUSD or USDC)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(steakhouseUSD)) {
            erc20Cooldown.transfer(steakhouseUSD, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(USDC)) {
            // Direct withdrawal from Morpho vault
            steakhouseUSD.withdraw(tokenAmount, receiver, address(this));
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev This function returns the current value of the strategy's assets in USDC.
     * @return baseAssets The total amount of USDC managed by this strategy
     */
    function totalAssets() external view returns (uint256 baseAssets) {
        uint256 shares = steakhouseUSD.balanceOf(address(this));
        baseAssets = steakhouseUSD.previewRedeem(shares);
        return baseAssets;
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in USDC
     * @dev This function handles conversion for both steakhouseUSD shares and USDC tokens.
     *      For steakhouseUSD shares, it uses the vault's exchange rate, considering the rounding direction.
     *      For USDC, it returns the input amount as is.
     * @param token The address of the token to convert (either steakhouseUSD or USDC)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in USDC
     */
    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        if (token == address(steakhouseUSD)) {
            return rounding == Math.Rounding.Floor
                ? steakhouseUSD.previewRedeem(tokenAmount)  // aka convertToAssets(tokenAmount)
                : steakhouseUSD.previewMint(tokenAmount);
        }
        if (token == address(USDC)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets (USDC) to the equivalent amount of supported tokens
     * @dev This function handles conversion for both steakhouseUSD shares and USDC tokens.
     *      For steakhouseUSD shares, it uses the vault's exchange rate, considering the rounding direction.
     *      For USDC, it returns the input amount as is.
     * @param token The address of the token to convert to (either steakhouseUSD or USDC)
     * @param baseAssets The amount of base assets (USDC) to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the requested token (steakhouseUSD shares or USDC)
     */
    function convertToTokens(address token, uint256 baseAssets, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        if (token == address(steakhouseUSD)) {
            return rounding == Math.Rounding.Floor
                ? steakhouseUSD.previewDeposit(baseAssets)  // aka convertToShares(baseAssets)
                : steakhouseUSD.previewWithdraw(baseAssets);
        }
        if (token == address(USDC)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Returns an array of supported tokens: steakhouseUSD shares and USDC
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(steakhouseUSD));
        tokens[1] = USDC;
        return tokens;
    }

    /**
     * @notice Updates the cooldown periods for steakhouseUSD share withdrawals
     */
    function setCooldowns(uint256 steakhouseUSDCooldownJrt_, uint256 steakhouseUSDCooldownSrt_)
        external
        onlyRole(UPDATER_STRAT_CONFIG_ROLE)
    {
        uint256 WEEK = 7 days;
        if (steakhouseUSDCooldownJrt_ > WEEK || steakhouseUSDCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        steakhouseUSDCooldownJrt = steakhouseUSDCooldownJrt_;
        steakhouseUSDCooldownSrt = steakhouseUSDCooldownSrt_;

        bool isDisabled = steakhouseUSDCooldownJrt_ == 0 && steakhouseUSDCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(steakhouseUSD, isDisabled);
        emit CooldownsChanged(steakhouseUSDCooldownJrt_, steakhouseUSDCooldownSrt_);
    }

    /**
     * @notice Sets the Merkl distributor contract address
     * @param distributor_ The address of the Merkl distributor contract
     */
    function setDistributor(IDistributor distributor_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        distributor = distributor_;
        emit DistributorUpdated(address(distributor_));
    }

    /**
     * @notice Sets the SwapContract address for swapping rewards
     * @param swapContract_ The address of the SwapContract
     */
    function setSwapContract(ISwapContract swapContract_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        swapContract = swapContract_;
        emit SwapContractUpdated(address(swapContract_));
    }

    /**
     * @notice Claims rewards from the Merkl distributor and swaps them to USDC
     * @dev This function claims rewards for this contract and swaps them to USDC using the SwapContract
     * @param tokens Array of reward token addresses to claim
     * @param amounts Array of cumulative amounts earned (from Merkle tree)
     * @param proofs Array of Merkle proofs for each claim
     * @param poolKeysData Array of ABI-encoded PoolKey structs for swapping each reward token to USDC
     * @param zeroForOnes Array of swap directions for each token
     * @param minAmountsOut Array of minimum USDC amounts expected from each swap (slippage protection)
     * @param deadline Timestamp after which the swaps will revert
     * @return totalUsdcReceived Total USDC received from all swaps
     */
    function claimRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        bytes[] calldata poolKeysData,
        bool[] calldata zeroForOnes,
        uint128[] calldata minAmountsOut,
        uint256 deadline
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) returns (uint256 totalUsdcReceived) {
        uint256 length = tokens.length;
        require(
            length == amounts.length && length == proofs.length && length == poolKeysData.length
                && length == zeroForOnes.length && length == minAmountsOut.length,
            "Array length mismatch"
        );
        require(address(distributor) != address(0), "Distributor not set");
        require(address(swapContract) != address(0), "SwapContract not set");

        // Build the users array - all claims are for this contract
        address[] memory users = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            users[i] = address(this);
        }

        // Claim rewards from the distributor
        distributor.claim(users, tokens, amounts, proofs);

        // Swap each reward token to USDC
        for (uint256 i = 0; i < length; i++) {
            address rewardToken = tokens[i];

            // Skip if the reward is already USDC
            if (rewardToken == address(USDC)) {
                uint256 usdcBalance = USDC.balanceOf(address(this));
                totalUsdcReceived += usdcBalance;
                emit RewardsClaimed(rewardToken, usdcBalance, usdcBalance);
                continue;
            }

            // Get the balance of the reward token we just claimed
            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
            if (rewardBalance == 0) continue;

            // Approve the SwapContract to spend the reward tokens
            SafeERC20.forceApprove(IERC20(rewardToken), address(swapContract), rewardBalance);

            // Swap the reward token to USDC
            uint256 usdcReceived = swapContract.swapWithEncodedKey(
                poolKeysData[i], zeroForOnes[i], uint128(rewardBalance), minAmountsOut[i], deadline, bytes("")
            );

            totalUsdcReceived += usdcReceived;
            emit RewardsClaimed(rewardToken, rewardBalance, usdcReceived);
        }

        return totalUsdcReceived;
    }
}
