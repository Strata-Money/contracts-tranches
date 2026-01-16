// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockERC4626} from "../contracts/test/MockERC4626.sol";

import {Tranche} from "../contracts/tranches/Tranche.sol";
import {Accounting} from "../contracts/tranches/Accounting.sol";

import {MorphoStrategy} from "../contracts/tranches/strategies/morpho/MorphoStrategy.sol";
import {AccessControlManager} from "../contracts/governance/AccessControlManager.sol";

import {AprPairFeed} from "../contracts/tranches/oracles/AprPairFeed.sol";
import {IStrategyAprPairProvider} from "../contracts/tranches/interfaces/IAprPairFeed.sol";

import {console2} from "forge-std/console2.sol";

import {StrataCDO} from "../contracts/tranches/StrataCDO.sol";

import {ERC20Cooldown} from "../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../contracts/tranches/base/cooldown/CooldownBase.sol";

import {ITranche} from "../contracts/tranches/interfaces/ITranche.sol";
import {IStrategy} from "../contracts/tranches/interfaces/IStrategy.sol";
import {IAccounting} from "../contracts/tranches/interfaces/IAccounting.sol";
import {IDistributor, MerkleTree} from "../contracts/tranches/interfaces/IDistributor.sol";
import {ISwapContract} from "../contracts/tranches/interfaces/ISwapContract.sol";

// Mock USDC token
contract MockUSDC is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Simple mock APR provider
contract MockAprPairProvider is IStrategyAprPairProvider {
    int64 public aprTarget = 500e9; // 5% scaled by 1e12
    int64 public aprBase = 800e9; // 8% scaled by 1e12

    function getAprPair() external view returns (int64, int64, uint64) {
        return (aprTarget, aprBase, uint64(block.timestamp));
    }

    function setAprs(int64 _aprTarget, int64 _aprBase) external {
        aprTarget = _aprTarget;
        aprBase = _aprBase;
    }
}

// Mock Distributor
contract MockDistributor is IDistributor {
    function claim(address[] calldata, address[] calldata, uint256[] calldata, bytes32[][] calldata)
        external
        override
    {}

    function claimWithRecipient(
        address[] calldata,
        address[] calldata,
        uint256[] calldata,
        bytes32[][] calldata,
        address[] calldata,
        bytes[] memory
    ) external override {}

    // Minimal implementation for interface compliance
    function tree() external pure override returns (bytes32, bytes32) {
        return (bytes32(0), bytes32(0));
    }

    function lastTree() external pure override returns (bytes32, bytes32) {
        return (bytes32(0), bytes32(0));
    }

    function disputeToken() external pure override returns (IERC20) {
        return IERC20(address(0));
    }

    function disputer() external pure override returns (address) {
        return address(0);
    }

    function endOfDisputePeriod() external pure override returns (uint48) {
        return 0;
    }

    function disputePeriod() external pure override returns (uint48) {
        return 0;
    }

    function disputeAmount() external pure override returns (uint256) {
        return 0;
    }

    function claimed(address, address) external pure override returns (uint208, uint48, bytes32) {
        return (0, 0, bytes32(0));
    }

    function canUpdateMerkleRoot(address) external pure override returns (uint256) {
        return 0;
    }

    function operators(address, address) external pure override returns (uint256) {
        return 0;
    }

    function upgradeabilityDeactivated() external pure override returns (uint128) {
        return 0;
    }

    function claimRecipient(address, address) external pure override returns (address) {
        return address(0);
    }

    function mainOperators(address, address) external pure override returns (uint256) {
        return 0;
    }

    function CALLBACK_SUCCESS() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function getMerkleRoot() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function getEpochDuration() external pure override returns (uint32) {
        return 0;
    }

    function toggleOperator(address, address) external override {}

    function setClaimRecipient(address, address) external override {}

    function toggleMainOperatorStatus(address, address) external override {}

    function disputeTree(string memory) external override {}

    function updateTree(MerkleTree calldata _tree) external override {}

    function toggleTrusted(address) external override {}

    function revokeUpgradeability() external override {}

    function setEpochDuration(uint32) external override {}

    function resolveDispute(bool) external override {}

    function revokeTree() external override {}

    function recoverERC20(address, address, uint256) external override {}

    function setDisputePeriod(uint48) external override {}

    function setDisputeToken(IERC20) external override {}

    function setDisputeAmount(uint256) external override {}
}

// Mock SwapContract
contract MockSwapContract is ISwapContract {
    function swapWithEncodedKey(bytes calldata, bool, uint128, uint128, uint256, bytes calldata)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function approveTokenWithPermit2(address, uint160, uint48) external override {}
}

contract MorphoStrategyTest is Test {
    // External protocols
    MockUSDC public USDC;
    MockERC4626 public morphoVault;

    // Auth
    AccessControlManager public acm;

    // Strata CDO
    StrataCDO public cdo;

    // Tranches
    Tranche public jrtVault;
    Tranche public srtVault;

    // Accounting Component
    Accounting public accounting;

    // Basic Feed
    AprPairFeed public feed;
    MockAprPairProvider public aprProvider;

    // Strategy
    MorphoStrategy public morphoStrategy;
    ERC20Cooldown public erc20Cooldown;

    address account;

    function setUp() public {
        address owner = msg.sender;

        vm.startPrank(owner);

        // Prepare USDC and morpho vault
        USDC = new MockUSDC();
        morphoVault = new MockERC4626(IERC20(address(USDC)));

        // Prepare Acm
        acm = new AccessControlManager(owner);

        // Create CDO
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(new StrataCDO()), abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );

        // Prepare Tranches
        jrtVault = Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche()),
                    abi.encodeWithSelector(
                        Tranche.initialize.selector,
                        owner,
                        address(acm),
                        "jrtVault",
                        "jrtUSDC",
                        IERC20(address(USDC)),
                        address(cdo)
                    )
                )
            )
        );
        srtVault = Tranche(
            address(
                new ERC1967Proxy(
                    address(new Tranche()),
                    abi.encodeWithSelector(
                        Tranche.initialize.selector,
                        owner,
                        address(acm),
                        "srtVault",
                        "srtUSDC",
                        IERC20(address(USDC)),
                        address(cdo)
                    )
                )
            )
        );

        // Prepare cooldown
        erc20Cooldown = ERC20Cooldown(
            address(
                new ERC1967Proxy(
                    address(new ERC20Cooldown()),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );

        // Prepare mocks for strategy constructor
        MockDistributor mockDistributor = new MockDistributor();
        MockSwapContract mockSwapContract = new MockSwapContract();
        uint256 vestingDuration = 30 days;

        // Prepare Strategy
        morphoStrategy = MorphoStrategy(
            address(
                new ERC1967Proxy(
                    address(
                        new MorphoStrategy(
                            IERC4626(address(morphoVault)),
                            IDistributor(address(mockDistributor)),
                            ISwapContract(address(mockSwapContract)),
                            vestingDuration
                        )
                    ),
                    abi.encodeWithSelector(
                        MorphoStrategy.initialize.selector, owner, address(acm), address(cdo), address(erc20Cooldown)
                    )
                )
            )
        );
        acm.grantRole(erc20Cooldown.COOLDOWN_WORKER_ROLE(), address(morphoStrategy));
        acm.grantRole(morphoStrategy.UPDATER_STRAT_CONFIG_ROLE(), owner);

        // Prepare Feed
        aprProvider = new MockAprPairProvider();
        feed = AprPairFeed(
            address(
                new ERC1967Proxy(
                    address(new AprPairFeed()),
                    abi.encodeWithSelector(
                        AprPairFeed.initialize.selector,
                        owner,
                        address(acm),
                        IStrategyAprPairProvider(address(aprProvider)),
                        4 hours,
                        "Morpho CDO APR Pair"
                    )
                )
            )
        );

        // Prepare accounting
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(new Accounting()),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector, owner, address(acm), address(cdo), address(feed)
                    )
                )
            )
        );

        // Configure CDO
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(morphoStrategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );
        acm.grantRole(cdo.PAUSER_ROLE(), owner);
        cdo.setActionStates(address(0), true, true);

        vm.stopPrank();
    }

    function test_Flow() public {
        assert(address(USDC) != address(0));

        account = msg.sender;
        address owner = msg.sender;

        vm.startPrank(owner);

        // Set cooldown periods (7 days for both tranches)
        uint256 cooldownPeriod = 7 days;
        morphoStrategy.setCooldowns(cooldownPeriod, cooldownPeriod);

        // test deposit
        uint256 shares = 1000 * 10 ** USDC.decimals(); // 1000 USDC
        USDC.mint(account, shares);
        USDC.approve(address(jrtVault), shares);
        jrtVault.deposit(address(USDC), shares, address(0xdead));
        assertBalance(jrtVault, address(0xdead), shares, "Deposit shares failed");

        USDC.mint(account, shares);
        USDC.approve(address(jrtVault), shares);
        jrtVault.deposit(address(USDC), shares, account);
        jrtVault.withdraw(address(USDC), shares, account, account);
        assertBalance(USDC, account, 0, "Cooldown period failed");

        vm.warp(block.timestamp + 7 days);
        erc20Cooldown.finalize(morphoVault, account);
        assertBalance(USDC, account, shares, "After-Cooldown period failed");

        vm.stopPrank();
    }

    function depositGeneric(IERC4626 vault, uint256 amount) internal {
        IERC20 asset = IERC20(vault.asset());
        asset.approve(address(vault), amount);
        vault.deposit(amount, account);
    }

    function assertBalance(IERC20 token, address owner, uint256 amount, string memory message) internal {
        uint256 balance = token.balanceOf(owner);
        assertEq(balance, amount, message);
    }
}

