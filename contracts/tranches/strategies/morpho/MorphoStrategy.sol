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

contract MorphoStrategy is Strategy {
    IERC4626 public immutable morphoVault;
    IERC20 public immutable asset;

    IERC20Cooldown public erc20Cooldown;

    /// @notice Merkl distributor contract for claiming rewards
    IDistributor public distributor;

    /// @notice SwapContract for swapping rewards to asset
    ISwapContract public swapContract;

    /**
     * configuration
     */
    uint256 public vaultCooldownJrt;
    uint256 public vaultCooldownSrt;

    /**
     * @notice Vesting configuration for reward deposits
     * @dev VestedUSDC tracks the total amount of USDC deposited from rewards that is still vesting.
     *      This amount decreases linearly over the vesting duration.
     */
    uint256 public vestedUSDC;
    uint256 public vestingDuration;
    uint256 public lastVestingUpdate;

    event CooldownsChanged(uint256 jrt, uint256 srt);
    event RewardsClaimed(address indexed rewardToken, uint256 rewardAmount, uint256 assetReceived);
    event DistributorUpdated(address indexed distributor);
    event SwapContractUpdated(address indexed swapContract);
    event VestingDurationUpdated(uint256 newDuration);

    constructor(IERC4626 vault_) {
        morphoVault = vault_;
        asset = IERC20(vault_.asset());
    }

    function initialize(address owner_, address acm_, IStrataCDO cdo_, IERC20Cooldown erc20Cooldown_)
        public
        virtual
        initializer
    {
        AccessControlled_init(owner_, acm_);

        cdo = cdo_;
        erc20Cooldown = erc20Cooldown_;

        SafeERC20.forceApprove(morphoVault, address(erc20Cooldown), type(uint256).max);

        // Initialize vesting state
        lastVestingUpdate = block.timestamp;
    }

    /**
     * @notice Processes asset deposits for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset deposits.
     *      If the deposited token is the base asset, it will be deposited to receive vault shares.
     *      If the deposited token is already vault shares, it will be accepted as is.
     * @param tranche The address of the tranche depositing assets (not used in this strategy)
     * @param token The address of the token being deposited
     * @param tokenAmount The amount of tokens being deposited
     * @param baseAssets The amount of base assets represented by the deposit (used for vault deposits)
     * @param owner The address of the asset owner from whom to transfer tokens
     * @return The amount of base assets received after deposit
     */
    function deposit(address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address owner)
        external
        onlyCDO
        returns (uint256)
    {
        SafeERC20.safeTransferFrom(IERC20(token), owner, address(this), tokenAmount);

        if (token == address(asset)) {
            SafeERC20.forceApprove(asset, address(morphoVault), tokenAmount);
            morphoVault.deposit(tokenAmount, address(this));
            return tokenAmount;
        }
        if (token == address(morphoVault)) {
            // already transferred in ↑
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Processes asset withdrawals for the CDO contract.
     * @dev This method is called by the CDO contract to handle asset withdrawals.
     *      If withdrawing vault shares, a cooldown period is applied based on the tranche type.
     *      If withdrawing the base asset, the vault shares are redeemed directly (no cooldown mechanism).
     *      An overloaded version accepts a shouldSkipCooldown parameter to skip the cooldown for vault share withdrawals.
     * @param tranche The address of the tranche withdrawing assets
     * @param token The address of the token to be withdrawn
     * @param tokenAmount The amount of tokens to be withdrawn (not used in this implementation)
     * @param baseAssets The amount of base assets to be withdrawn
     * @param receiver The address that will receive the withdrawn assets
     * @param sender The account that initiated the withdrawal
     * @return The amount of tokens withdrawn (shares for vault, baseAssets for base asset)
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
        uint256 shares = morphoVault.previewWithdraw(baseAssets);
        if (token == address(morphoVault)) {
            uint256 cooldownSeconds =
                shouldSkipCooldown ? 0 : (cdo.isJrt(tranche) ? vaultCooldownJrt : vaultCooldownSrt);
            erc20Cooldown.transfer(morphoVault, sender, receiver, shares, cooldownSeconds);
            return shares;
        }
        if (token == address(asset)) {
            // Morpho allows direct withdrawal - no cooldown needed
            morphoVault.withdraw(baseAssets, receiver, address(this));
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Allows the CDO to withdraw tokens from the strategy's reserve
     * @dev This function is part of the reserve reduction process and can only be called by the CDO.
     *      It handles both vault shares and base asset tokens, applying different transfer mechanisms for each.
     *      For vault shares, it uses erc20Cooldown with no cooldown period.
     *      For base asset, it withdraws directly from the Morpho vault.
     * @param token The address of the token to be withdrawn (either vault shares or base asset)
     * @param tokenAmount The amount of tokens to be withdrawn
     * @param receiver The address that will receive the withdrawn tokens
     */
    function reduceReserve(address token, uint256 tokenAmount, address receiver) external onlyCDO {
        if (token == address(morphoVault)) {
            erc20Cooldown.transfer(morphoVault, receiver, receiver, tokenAmount, 0);
            return;
        }
        if (token == address(asset)) {
            // Direct withdrawal from Morpho vault
            morphoVault.withdraw(tokenAmount, receiver, address(this));
            return;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Calculates the current unvested USDC amount
     * @dev Returns the amount of USDC that is still vesting, decreasing linearly over time
     * @return The amount of unvested USDC
     */
    function getUnvestedUSDC() public view returns (uint256) {
        if (vestedUSDC == 0 || vestingDuration == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp > lastVestingUpdate ? block.timestamp - lastVestingUpdate : 0;

        if (elapsed >= vestingDuration) {
            return 0; // Fully vested
        }

        // Linear vesting: unvested = vestedUSDC * (1 - elapsed / duration)
        // Using: unvested = vestedUSDC * (vestingDuration - elapsed) / vestingDuration
        return (vestedUSDC * (vestingDuration - elapsed)) / vestingDuration;
    }

    /**
     * @notice Updates the vesting state by applying time decay
     * @dev This should be called before modifying vestedUSDC to apply time-based decay.
     *      When vesting occurs, the newly vested amount is transferred to the junior vault
     *      so that users can withdraw their money back.
     */
    function _updateVesting() internal {
        uint256 vestedUSDCBefore = vestedUSDC;

        if (vestedUSDC > 0 && vestingDuration > 0 && lastVestingUpdate > 0) {
            uint256 elapsed = block.timestamp > lastVestingUpdate ? block.timestamp - lastVestingUpdate : 0;

            if (elapsed >= vestingDuration) {
                // Fully vested, reset to zero
                vestedUSDC = 0;
            } else {
                // Apply linear decay
                vestedUSDC = (vestedUSDC * (vestingDuration - elapsed)) / vestingDuration;
            }
        }
        lastVestingUpdate = block.timestamp;

        // Calculate newly vested amount and transfer to junior vault
        if (vestedUSDCBefore > vestedUSDC) {
            uint256 newlyVested = vestedUSDCBefore - vestedUSDC;
            _transferVestedToJuniorVault(newlyVested);
        }
    }

    /**
     * @notice Transfers newly vested assets to the junior vault
     * @dev Uses USDC already in the strategy contract (from current reward claims after swapping).
     *      Transfers assets directly to the vault to increase its total value without minting shares.
     *      The vestedUSDC is kept as USDC in the strategy contract, not deposited to the vault.
     *      If the junior vault is not yet configured, the transfer is skipped.
     * @param newlyVested The amount of newly vested base assets to transfer
     */
    function _transferVestedToJuniorVault(uint256 newlyVested) internal {
        if (newlyVested == 0) return;

        // Skip if junior vault is not configured yet
        if (address(cdo.jrtVault()) == address(0)) {
            return;
        }

        // The USDC should already be in the strategy contract from reward claims
        // Transfer directly to the vault to increase its total value without minting shares
        SafeERC20.safeTransfer(asset, address(cdo.jrtVault()), newlyVested);
    }

    /**
     * @notice Calculates the total assets managed by this strategy
     * @dev This function returns the current value of the strategy's assets in the base asset.
     * @return baseAssets The total amount of base asset managed by this strategy
     */
    function totalAssets() external view returns (uint256 baseAssets) {
        uint256 shares = morphoVault.balanceOf(address(this));
        baseAssets = morphoVault.previewRedeem(shares);

        // Add USDC balance in strategy contract (where vestedUSDC is held)
        uint256 usdcBalance = asset.balanceOf(address(this));
        baseAssets += usdcBalance;

        // Subtract unvested USDC from rewards
        uint256 unvested = getUnvestedUSDC();
        if (baseAssets > unvested) {
            baseAssets -= unvested;
        } else {
            baseAssets = 0;
        }

        return baseAssets;
    }

    /**
     * @notice Converts a given amount of supported tokens to their equivalent in the base asset
     * @dev This function handles conversion for both vault shares and base asset tokens.
     *      For vault shares, it uses the vault's exchange rate, considering the rounding direction.
     *      For base asset, it returns the input amount as is.
     * @param token The address of the token to convert (either vault shares or base asset)
     * @param tokenAmount The amount of tokens to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the base asset
     */
    function convertToAssets(address token, uint256 tokenAmount, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        if (token == address(morphoVault)) {
            return rounding == Math.Rounding.Floor
                ? morphoVault.previewRedeem(tokenAmount)  // aka convertToAssets(tokenAmount)
                : morphoVault.previewMint(tokenAmount);
        }
        if (token == address(asset)) {
            return tokenAmount;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Converts a given amount of base assets to the equivalent amount of supported tokens
     * @dev This function handles conversion for both vault shares and base asset tokens.
     *      For vault shares, it uses the vault's exchange rate, considering the rounding direction.
     *      For base asset, it returns the input amount as is.
     * @param token The address of the token to convert to (either vault shares or base asset)
     * @param baseAssets The amount of base assets to convert
     * @param rounding The rounding direction to use for the conversion (floor or ceiling)
     * @return The equivalent amount in the requested token (vault shares or base asset)
     */
    function convertToTokens(address token, uint256 baseAssets, Math.Rounding rounding)
        external
        view
        returns (uint256)
    {
        if (token == address(morphoVault)) {
            return rounding == Math.Rounding.Floor
                ? morphoVault.previewDeposit(baseAssets)  // aka convertToShares(baseAssets)
                : morphoVault.previewWithdraw(baseAssets);
        }
        if (token == address(asset)) {
            return baseAssets;
        }
        revert UnsupportedToken(token);
    }

    /**
     * @notice Returns an array of supported tokens: vault shares and base asset
     */
    function getSupportedTokens() external view returns (IERC20[] memory) {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(morphoVault));
        tokens[1] = asset;
        return tokens;
    }

    /**
     * @notice Updates the cooldown periods for vault share withdrawals
     */
    function setCooldowns(uint256 vaultCooldownJrt_, uint256 vaultCooldownSrt_)
        external
        onlyRole(UPDATER_STRAT_CONFIG_ROLE)
    {
        uint256 WEEK = 7 days;
        if (vaultCooldownJrt_ > WEEK || vaultCooldownSrt_ > WEEK) {
            revert InvalidConfigCooldown();
        }
        vaultCooldownJrt = vaultCooldownJrt_;
        vaultCooldownSrt = vaultCooldownSrt_;

        bool isDisabled = vaultCooldownJrt_ == 0 && vaultCooldownSrt_ == 0;
        erc20Cooldown.setCooldownDisabled(morphoVault, isDisabled);
        emit CooldownsChanged(vaultCooldownJrt_, vaultCooldownSrt_);
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
     * @notice Claims rewards from the Merkl distributor, swaps them to the base asset, and deposits to Junior Vault
     * @dev This function claims rewards for this contract, swaps them to the base asset using the SwapContract,
     *      and deposits the resulting assets into the Morpho vault. The increased vault shares benefit the
     *      strategy's totalAssets which flows through CDO accounting to the Junior tranche.
     * @param tokens Array of reward token addresses to claim
     * @param amounts Array of cumulative amounts earned (from Merkle tree)
     * @param proofs Array of Merkle proofs for each claim
     * @param poolKeysData Array of ABI-encoded PoolKey structs for swapping each reward token to base asset
     * @param zeroForOnes Array of swap directions for each token
     * @param minAmountsOut Array of minimum base asset amounts expected from each swap (slippage protection)
     * @param deadline Timestamp after which the swaps will revert
     * @return totalAssetReceived Total base asset received from all swaps and deposited to vault
     */
    function claimRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        bytes[] calldata poolKeysData,
        bool[] calldata zeroForOnes,
        uint128[] calldata minAmountsOut,
        uint256 deadline
    ) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) returns (uint256 totalAssetReceived) {
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

        // Swap each reward token to the base asset
        for (uint256 i = 0; i < length; i++) {
            address rewardToken = tokens[i];

            // Skip if the reward is already the base asset
            if (rewardToken == address(asset)) {
                uint256 assetBalance = asset.balanceOf(address(this));
                totalAssetReceived += assetBalance;
                emit RewardsClaimed(rewardToken, assetBalance, assetBalance);
                continue;
            }

            // Get the balance of the reward token we just claimed
            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
            if (rewardBalance == 0) continue;

            // Approve the SwapContract to spend the reward tokens
            SafeERC20.forceApprove(IERC20(rewardToken), address(swapContract), rewardBalance);

            // Swap the reward token to the base asset
            uint256 assetReceived = swapContract.swapWithEncodedKey(
                poolKeysData[i], zeroForOnes[i], uint128(rewardBalance), minAmountsOut[i], deadline, bytes("")
            );

            totalAssetReceived += assetReceived;
            emit RewardsClaimed(rewardToken, rewardBalance, assetReceived);
        }

        // Handle vesting - vestedUSDC is kept as USDC in the strategy contract
        // This benefits the Junior tranche through the CDO accounting mechanism
        if (totalAssetReceived > 0) {
            // Update vesting state - this will transfer newly vested amounts to junior vault
            // using the USDC currently in the strategy contract from this claim
            _updateVesting();

            // Track the new reward deposit as vested USDC (stays as USDC in strategy, not in vault)
            vestedUSDC += totalAssetReceived;
        }

        return totalAssetReceived;
    }

    /**
     * @notice Sets the vesting duration for reward deposits
     * @param vestingDuration_ The duration in seconds over which rewards vest (decrease to 0)
     */
    function setVestingDuration(uint256 vestingDuration_) external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        // Update vesting state before changing duration
        _updateVesting();

        vestingDuration = vestingDuration_;
        emit VestingDurationUpdated(vestingDuration_);
    }
}

