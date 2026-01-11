// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Merkle tree structure for reward distribution
struct MerkleTree {
    /// @notice Root of a Merkle tree whose leaves are `(address user, address token, uint amount)`
    bytes32 merkleRoot;
    /// @dev Deprecated: this used to be the IPFS hash of the complete tree data
    bytes32 ipfsHash;
}

/// @notice Claim tracking structure
struct Claim {
    /// @notice Cumulative amount claimed by the user for this token
    uint208 amount;
    /// @notice Timestamp of the last claim
    uint48 timestamp;
    /// @notice Merkle root that was active when the last claim occurred
    bytes32 merkleRoot;
}

/// @title IDistributor
/// @notice Interface for the Merkl Distributor contract
/// @dev Manages the distribution of Merkl rewards and allows users to claim their earned tokens
interface IDistributor {
    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                        EVENTS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    event Claimed(address indexed user, address indexed token, uint256 amount);
    event ClaimRecipientUpdated(address indexed user, address indexed token, address indexed recipient);
    event DisputeAmountUpdated(uint256 _disputeAmount);
    event Disputed(string reason);
    event DisputePeriodUpdated(uint48 _disputePeriod);
    event DisputeResolved(bool valid);
    event DisputeTokenUpdated(address indexed _disputeToken);
    event EpochDurationUpdated(uint32 newEpochDuration);
    event MainOperatorStatusUpdated(address indexed operator, address indexed token, bool isWhitelisted);
    event OperatorClaimingToggled(address indexed user, bool isEnabled);
    event OperatorToggled(address indexed user, address indexed operator, bool isWhitelisted);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event Revoked();
    event TreeUpdated(bytes32 merkleRoot, bytes32 ipfsHash, uint48 endOfDisputePeriod);
    event TrustedToggled(address indexed eoa, bool trust);
    event UpgradeabilityRevoked();

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                    PUBLIC VARIABLES
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Current active Merkle tree containing claimable token data
    function tree() external view returns (bytes32 merkleRoot, bytes32 ipfsHash);

    /// @notice Previous Merkle tree that was active before the last update
    function lastTree() external view returns (bytes32 merkleRoot, bytes32 ipfsHash);

    /// @notice Token required as a deposit to dispute a tree update
    function disputeToken() external view returns (IERC20);

    /// @notice Address that created the current ongoing dispute
    function disputer() external view returns (address);

    /// @notice Timestamp after which the current tree becomes effective and undisputable
    function endOfDisputePeriod() external view returns (uint48);

    /// @notice Number of epochs to wait before a tree update becomes effective
    function disputePeriod() external view returns (uint48);

    /// @notice Amount of disputeToken required to create a dispute
    function disputeAmount() external view returns (uint256);

    /// @notice Tracks cumulative claimed amounts for each user and token
    function claimed(address user, address token)
        external
        view
        returns (uint208 amount, uint48 timestamp, bytes32 merkleRoot);

    /// @notice Trusted addresses authorized to update the Merkle root
    function canUpdateMerkleRoot(address) external view returns (uint256);

    /// @notice Authorization for operators to claim on behalf of users
    function operators(address user, address operator) external view returns (uint256);

    /// @notice Whether contract upgradeability has been permanently disabled
    function upgradeabilityDeactivated() external view returns (uint128);

    /// @notice Custom recipient addresses for user claims per token
    function claimRecipient(address user, address token) external view returns (address);

    /// @notice Global operators authorized to claim specific tokens on behalf of any user
    function mainOperators(address operator, address token) external view returns (uint256);

    /// @notice Success message that must be returned by `IClaimRecipient.onClaim` callback
    function CALLBACK_SUCCESS() external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                    MAIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Claims rewards for a set of users based on Merkle proofs
    /// @param users Addresses claiming rewards (or being claimed for)
    /// @param tokens ERC20 tokens being claimed
    /// @param amounts Cumulative amounts earned (not incremental amounts)
    /// @param proofs Merkle proofs validating each claim
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    /// @notice Claims rewards with custom recipient addresses and callback data
    /// @param users Addresses claiming rewards (or being claimed for)
    /// @param tokens ERC20 tokens being claimed
    /// @param amounts Cumulative amounts earned (not incremental amounts)
    /// @param proofs Merkle proofs validating each claim
    /// @param recipients Custom recipient addresses for each claim
    /// @param datas Arbitrary data passed to recipient's onClaim callback
    function claimWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients,
        bytes[] memory datas
    ) external;

    /// @notice Returns the currently active Merkle root for claim verification
    function getMerkleRoot() external view returns (bytes32);

    /// @notice Returns the epoch duration used for dispute period calculations
    function getEpochDuration() external view returns (uint32 epochDuration);

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                 USER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Toggles an operator's authorization to claim rewards on behalf of a user
    function toggleOperator(address user, address operator) external;

    /// @notice Sets a custom recipient address for a user's token claims
    function setClaimRecipient(address recipient, address token) external;

    /// @notice Toggles a main operator's authorization to claim tokens on behalf of any user
    function toggleMainOperatorStatus(address operator, address token) external;

    /// @notice Creates a dispute to freeze the current Merkle tree update
    function disputeTree(string memory reason) external;

    /*//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
                                                 GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////*/

    /// @notice Updates the active Merkle tree with new reward data
    function updateTree(MerkleTree calldata _tree) external;

    /// @notice Toggles an address's authorization to update the Merkle tree
    function toggleTrusted(address trustAddress) external;

    /// @notice Permanently disables contract upgradeability
    function revokeUpgradeability() external;

    /// @notice Updates the epoch duration used for dispute period calculations
    function setEpochDuration(uint32 epochDuration) external;

    /// @notice Resolves an ongoing dispute
    function resolveDispute(bool valid) external;

    /// @notice Reverts to the previous Merkle tree immediately
    function revokeTree() external;

    /// @notice Recovers ERC20 tokens accidentally sent to the contract
    function recoverERC20(address tokenAddress, address to, uint256 amountToRecover) external;

    /// @notice Updates the dispute period duration
    function setDisputePeriod(uint48 _disputePeriod) external;

    /// @notice Updates the token required as collateral for disputes
    function setDisputeToken(IERC20 _disputeToken) external;

    /// @notice Updates the amount of tokens required to create a dispute
    function setDisputeAmount(uint256 _disputeAmount) external;
}

