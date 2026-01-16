// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AccessControlManager} from "../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../contracts/tranches/Tranche.sol";
import {Accounting} from "../contracts/tranches/Accounting.sol";
import {AprPairFeed} from "../contracts/tranches/oracles/AprPairFeed.sol";

import {MorphoStrategy} from "../contracts/tranches/strategies/morpho/MorphoStrategy.sol";
import {MorphoAprPairProvider} from "../contracts/tranches/strategies/morpho/MorphoAprPairProvider.sol";

import {ERC20Cooldown} from "../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {CooldownBase} from "../contracts/tranches/base/cooldown/CooldownBase.sol";

import {IAccounting} from "../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../contracts/tranches/interfaces/IAprPairFeed.sol";
import {IERC20Cooldown} from "../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {IDistributor, MerkleTree} from "../contracts/tranches/interfaces/IDistributor.sol";
import {ISwapContract} from "../contracts/tranches/interfaces/ISwapContract.sol";

contract SmokehouseDeploy is Test {
    // Mainnet addresses
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Smokehouse USDC vault - the base vault for strategy and base APR
    address public constant SMOKEHOUSE_USDC = 0xBEeFFF209270748ddd194831b3fa287a5386f5bC;

    // Steakhouse USDC vault - the target vault for target APR
    address public constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    // USDC address on mainnet
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Smokehouse was deployed at a recent block
    uint256 constant MAINNET_BLOCK = 21834000;

    // Roles
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant CDO_OWNER_ROLE = keccak256("CDO_OWNER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    // Mock contracts for strategy constructor
    MockDistributor internal mockDistributor;
    MockSwapContract internal mockSwapContract;

    // Deployed contracts
    address internal owner;
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    MorphoStrategy internal strategy;
    MorphoAprPairProvider internal provider;
    AprPairFeed internal feed;
    Accounting internal accounting;

    function setUp() public virtual {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl, MAINNET_BLOCK);
        vm.selectFork(forkId);

        owner = makeAddr("strataOwner");
        vm.label(owner, "DeployerOwner");
        vm.label(MORPHO, "Morpho");
        vm.label(SMOKEHOUSE_USDC, "SmokehouseUSDC");
        vm.label(STEAKHOUSE_USDC, "SteakhouseUSDC");
        vm.label(USDC, "USDC");

        vm.deal(owner, 100 ether);

        // Deploy mock contracts for strategy constructor
        mockDistributor = new MockDistributor();
        mockSwapContract = new MockSwapContract();
    }

    function testDeploySmokehouseStackMatchesScript() public {
        _deployStrataStack();

        // Verify CDO configuration
        assertEq(address(cdo.strategy()), address(strategy));
        assertEq(address(cdo.jrtVault()), address(jrtVault));
        assertEq(address(cdo.srtVault()), address(srtVault));
        assertEq(jrtVault.asset(), USDC);
        assertEq(srtVault.asset(), USDC);

        // Verify strategy configuration
        assertEq(address(strategy.morphoVault()), SMOKEHOUSE_USDC);
        assertEq(address(strategy.asset()), USDC);
        assertEq(strategy.vaultCooldownJrt(), 7 days);
        assertEq(strategy.vaultCooldownSrt(), 0);

        // Verify provider configuration
        assertEq(address(provider.morpho()), MORPHO);
        assertEq(provider.baseVault(), SMOKEHOUSE_USDC);
        assertEq(provider.targetVault(), STEAKHOUSE_USDC);

        // Verify feed configuration
        assertEq(address(feed.provider()), address(provider));
        assertEq(feed.roundStaleAfter(), 4 hours);
        assertEq(address(accounting.aprPairFeed()), address(feed));

        // Verify roles
        assertTrue(acm.hasRole(PAUSER_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_FEED_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_CDO_APR_ROLE, address(feed)));
        assertTrue(acm.hasRole(COOLDOWN_WORKER_ROLE, address(strategy)));

        // Verify action states
        (bool jrtDepositsEnabled, bool jrtWithdrawalsEnabled) = cdo.actionsJrt();
        (bool srtDepositsEnabled, bool srtWithdrawalsEnabled) = cdo.actionsSrt();
        assertTrue(jrtDepositsEnabled && jrtWithdrawalsEnabled);
        assertTrue(srtDepositsEnabled && srtWithdrawalsEnabled);

        // Verify supported tokens
        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 2);
        assertEq(address(supported[0]), SMOKEHOUSE_USDC);
        assertEq(address(supported[1]), USDC);
    }

    function testAprPairProviderReturnsValidData() public {
        _deployStrataStack();

        (int64 aprTarget, int64 aprBase, uint64 timestamp) = provider.getAprPair();

        // APRs should be positive and reasonable (< 100% = 1e12)
        assertTrue(aprTarget >= 0, "Target APR should be non-negative");
        assertTrue(aprBase >= 0, "Base APR should be non-negative");
        assertTrue(aprTarget < 1e12, "Target APR should be less than 100%");
        assertTrue(aprBase < 1e12, "Base APR should be less than 100%");
        assertEq(timestamp, uint64(block.timestamp));
    }

    function _deployStrataStack() internal {
        vm.startPrank(owner);

        // 1. Deploy AccessControlManager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        // 2. Deploy StrataCDO
        StrataCDO cdoImpl = new StrataCDO();
        vm.label(address(cdoImpl), "StrataCDO_Impl");
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(cdoImpl), abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(cdo), "StrataCDO");

        // 3. Deploy Tranches
        jrtVault = _deployTranche("JRT", "Junior Tranche");
        srtVault = _deployTranche("SRT", "Senior Tranche");

        // 4. Deploy ERC20Cooldown
        ERC20Cooldown erc20CooldownImpl = new ERC20Cooldown();
        vm.label(address(erc20CooldownImpl), "ERC20Cooldown_Impl");
        erc20Cooldown = ERC20Cooldown(
            address(
                new ERC1967Proxy(
                    address(erc20CooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );
        vm.label(address(erc20Cooldown), "ERC20Cooldown");

        // 5. Deploy MorphoStrategy (uses Smokehouse vault)
        MorphoStrategy strategyImpl = new MorphoStrategy(
            IERC4626(SMOKEHOUSE_USDC),
            IDistributor(address(mockDistributor)),
            ISwapContract(address(mockSwapContract)),
            30 days // vestingDuration
        );
        vm.label(address(strategyImpl), "MorphoStrategy_Impl");
        strategy = MorphoStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        MorphoStrategy.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        IERC20Cooldown(address(erc20Cooldown))
                    )
                )
            )
        );
        vm.label(address(strategy), "MorphoStrategy");

        // 6. Deploy MorphoAprPairProvider
        // baseVault = Smokehouse (for base APR), targetVault = Steakhouse (for target APR)
        provider = new MorphoAprPairProvider(MORPHO, SMOKEHOUSE_USDC, STEAKHOUSE_USDC);
        vm.label(address(provider), "MorphoAprPairProvider");

        // 7. Deploy AprPairFeed
        AprPairFeed feedImpl = new AprPairFeed();
        vm.label(address(feedImpl), "AprPairFeed_Impl");
        feed = AprPairFeed(
            address(
                new ERC1967Proxy(
                    address(feedImpl),
                    abi.encodeWithSelector(
                        AprPairFeed.initialize.selector,
                        owner,
                        address(acm),
                        provider,
                        uint256(4 hours),
                        "Smokehouse CDO APR Pair"
                    )
                )
            )
        );
        vm.label(address(feed), "AprPairFeed");

        // 8. Deploy Accounting
        Accounting accountingImpl = new Accounting();
        vm.label(address(accountingImpl), "Accounting_Impl");
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(accountingImpl),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector,
                        owner,
                        address(acm),
                        IStrataCDO(address(cdo)),
                        IAprPairFeed(address(feed))
                    )
                )
            )
        );
        vm.label(address(accounting), "Accounting");

        // 9. Grant roles
        _grantRole(PAUSER_ROLE, owner);
        _grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        _grantRole(UPDATER_FEED_ROLE, owner);
        _grantRole(UPDATER_CDO_APR_ROLE, address(feed));
        _grantRole(COOLDOWN_WORKER_ROLE, address(strategy));

        // 10. Configure CDO
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );

        // 11. Set strategy cooldowns (7 days for JRT, 0 for SRT)
        strategy.setCooldowns(7 days, 0);

        // 12. Enable actions on tranches
        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

        // 13. Set reserve basis points
        accounting.setReserveBps(0.02e18);

        vm.stopPrank();
    }

    function _deployTranche(string memory name, string memory symbol) internal returns (Tranche) {
        Tranche trancheImpl = new Tranche();
        vm.label(address(trancheImpl), string.concat(name, "_Tranche_Impl"));

        address proxy = address(
            new ERC1967Proxy(
                address(trancheImpl),
                abi.encodeWithSelector(
                    Tranche.initialize.selector,
                    owner,
                    address(acm),
                    name,
                    symbol,
                    IERC20(USDC),
                    IStrataCDO(address(cdo))
                )
            )
        );
        string memory label = string.concat(name, "_Tranche");
        vm.label(proxy, label);
        return Tranche(proxy);
    }

    function _grantRole(bytes32 role, address grantee) internal {
        acm.grantRole(role, grantee);
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

