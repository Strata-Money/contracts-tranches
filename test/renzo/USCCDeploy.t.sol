// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {AccessControlManager} from "../../contracts/governance/AccessControlManager.sol";
import {StrataCDO} from "../../contracts/tranches/StrataCDO.sol";
import {Tranche} from "../../contracts/tranches/Tranche.sol";
import {Accounting} from "../../contracts/tranches/Accounting.sol";
import {AprPairFeed} from "../../contracts/tranches/oracles/AprPairFeed.sol";
import {sUSCCStrategy as SUSCCStrategy} from "../../contracts/tranches/strategies/renzo/sUSCCStrategy.sol";
import {
    sUSCCAprPairProvider as SUSCCAprPairProvider,
    IsUSDS
} from "../../contracts/tranches/strategies/renzo/sUSCCAprPairProvider.sol";
import {IsUSCC} from "../../contracts/tranches/strategies/renzo/interfaces/IsUSCC.sol";
import {sUSCCCooldownRequestImpl} from "../../contracts/tranches/strategies/renzo/sUSCCCooldownRequestImpl.sol";

import {ERC20Cooldown} from "../../contracts/tranches/base/cooldown/ERC20Cooldown.sol";
import {UnstakeCooldown} from "../../contracts/tranches/base/cooldown/UnstakeCooldown.sol";
import {CooldownBase} from "../../contracts/tranches/base/cooldown/CooldownBase.sol";
import {IUnstakeHandler} from "../../contracts/tranches/interfaces/cooldown/IUnstakeHandler.sol";
import {ICooldown} from "../../contracts/tranches/interfaces/cooldown/ICooldown.sol";
import {IAccounting} from "../../contracts/tranches/interfaces/IAccounting.sol";
import {IStrategy} from "../../contracts/tranches/interfaces/IStrategy.sol";
import {ITranche} from "../../contracts/tranches/interfaces/ITranche.sol";
import {IStrataCDO} from "../../contracts/tranches/interfaces/IStrataCDO.sol";
import {IAprPairFeed} from "../../contracts/tranches/interfaces/IAprPairFeed.sol";
import {IErrors} from "../../contracts/tranches/interfaces/IErrors.sol";

import {LEZyVault} from "../../contracts/test/renzo/LEZyVault.sol";
import {IRoleManager} from "../../contracts/test/renzo/interfaces/IRoleManager.sol";
import {WithdrawQueue} from "../../contracts/test/renzo/WithdrawQueue.sol";

contract USCCDeploy is Test {
    LEZyVault public ezUSCC;
    address public owner;
    address public feeRecipient;
    address public depositor;

    address public constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Mainnet addresses
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // USDC whale for forking
    address public constant USDC_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance hot wallet

    uint256 public constant MAINNET_BLOCK = 23_000_000; // Update with appropriate block number

    // Roles
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UPDATER_STRAT_CONFIG_ROLE = keccak256("UPDATER_STRAT_CONFIG_ROLE");
    bytes32 constant UPDATER_FEED_ROLE = keccak256("UPDATER_FEED_ROLE");
    bytes32 constant UPDATER_CDO_APR_ROLE = keccak256("UPDATER_CDO_APR_ROLE");
    bytes32 constant RESERVE_MANAGER_ROLE = keccak256("RESERVE_MANAGER_ROLE");
    bytes32 constant CDO_OWNER_ROLE = keccak256("CDO_OWNER_ROLE");
    bytes32 constant COOLDOWN_WORKER_ROLE = keccak256("COOLDOWN_WORKER_ROLE");

    // Deployed contracts
    AccessControlManager internal acm;
    StrataCDO internal cdo;
    Tranche internal jrtVault;
    Tranche internal srtVault;
    ERC20Cooldown internal erc20Cooldown;
    UnstakeCooldown internal unstakeCooldown;
    sUSCCCooldownRequestImpl internal cooldownRequestImpl;
    SUSCCStrategy internal strategy;
    SUSCCAprPairProvider internal provider;
    AprPairFeed internal feed;
    Accounting internal accounting;

    // Mock contracts
    MockRoleManager public roleManager;
    MockWithdrawQueue public mockWithdrawQueue;
    UpgradeableBeacon public withdrawQueueBeacon;
    MockSUSDS public sUSDS;

    function setUp() public virtual {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");

        uint256 forkId = vm.createFork(rpcUrl, MAINNET_BLOCK);
        vm.selectFork(forkId);

        owner = makeAddr("strataOwner");
        feeRecipient = makeAddr("feeRecipient");
        depositor = makeAddr("depositor");

        vm.label(owner, "Owner");
        vm.label(feeRecipient, "FeeRecipient");
        vm.label(depositor, "Depositor");
        vm.label(USDC, "USDC");
        vm.deal(owner, 100 ether);

        roleManager = new MockRoleManager();

        mockWithdrawQueue = new MockWithdrawQueue();
        withdrawQueueBeacon = new UpgradeableBeacon(address(mockWithdrawQueue), owner);

        LEZyVault ezUSCCImpl = new LEZyVault(IBeacon(address(withdrawQueueBeacon)), WETH);

        // Deploy vault as proxy
        address proxyAddress = address(
            new ERC1967Proxy(
                address(ezUSCCImpl),
                abi.encodeWithSelector(
                    LEZyVault.initialize.selector,
                    IERC20(USDC), // asset
                    "Renzo USDC", // name
                    "USCC", // symbol
                    roleManager, // roleManager
                    owner, // owner
                    feeRecipient, // feeRecipient
                    1000, // feeBps (10%)
                    7 days // withdrawCoolDownPeriod
                )
            )
        );

        ezUSCC = LEZyVault(payable(proxyAddress));

        // Disable whitelist for testing
        vm.prank(owner);
        ezUSCC.setDepositWhitelistEnabled(false);

        // Deploy mock sUSDS for APR target
        sUSDS = new MockSUSDS();
        vm.label(address(sUSDS), "sUSDS");
    }

    function testDeploySuperstateStackMatchesScript() public {
        _deployStrataStack();

        // Verify CDO configuration
        assertEq(address(cdo.strategy()), address(strategy));
        assertEq(address(cdo.jrtVault()), address(jrtVault));
        assertEq(address(cdo.srtVault()), address(srtVault));
        assertEq(jrtVault.asset(), USDC);
        assertEq(srtVault.asset(), USDC);

        // Verify strategy configuration
        assertEq(address(strategy.ezUSCC1()), address(ezUSCC));
        assertEq(address(strategy.USDC()), USDC);
        assertEq(address(strategy.erc20Cooldown()), address(erc20Cooldown));
        assertEq(address(strategy.unstakeCooldown()), address(unstakeCooldown));

        // Verify feed config
        assertEq(address(feed.provider()), address(provider));
        assertEq(feed.roundStaleAfter(), 4 hours);
        assertEq(address(accounting.aprPairFeed()), address(feed));

        // Verify cooldown implementations
        assertEq(address(unstakeCooldown.implementations(address(ezUSCC))), address(cooldownRequestImpl));

        // Verify roles
        assertTrue(acm.hasRole(PAUSER_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_STRAT_CONFIG_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_FEED_ROLE, owner));
        assertTrue(acm.hasRole(UPDATER_CDO_APR_ROLE, address(feed)));
        assertTrue(acm.hasRole(COOLDOWN_WORKER_ROLE, address(strategy)));
        assertTrue(acm.hasRole(COOLDOWN_WORKER_ROLE, owner));

        // Verify action states
        (bool jrtDepositsEnabled, bool jrtWithdrawalsEnabled) = cdo.actionsJrt();
        (bool srtDepositsEnabled, bool srtWithdrawalsEnabled) = cdo.actionsSrt();
        assertTrue(jrtDepositsEnabled && jrtWithdrawalsEnabled);
        assertTrue(srtDepositsEnabled && srtWithdrawalsEnabled);

        // Verify supported tokens
        IERC20[] memory supported = strategy.getSupportedTokens();
        assertEq(supported.length, 1);
        assertEq(address(supported[0]), USDC);
    }

    function _deployStrataStack() internal {
        vm.startPrank(owner);

        // 1. Deploy AccessControlManager
        acm = new AccessControlManager(owner);
        vm.label(address(acm), "AccessControlManager");

        // 2. Deploy StrataCDO
        cdo = StrataCDO(
            address(
                new ERC1967Proxy(
                    address(new StrataCDO()), abi.encodeWithSelector(StrataCDO.initialize.selector, owner, address(acm))
                )
            )
        );

        // 3. Deploy Tranches
        jrtVault = _deployTranche("JRT", "Junior Tranch");
        srtVault = _deployTranche("SRT", "Senior Tranch");

        // 4. Deploy ERC20Cooldown
        ERC20Cooldown erc20CooldownImpl = new ERC20Cooldown();
        erc20Cooldown = ERC20Cooldown(
            address(
                new ERC1967Proxy(
                    address(erc20CooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );

        // 5. Deploy UnstakeCooldown
        UnstakeCooldown unstakeCooldownImpl = new UnstakeCooldown();
        unstakeCooldown = UnstakeCooldown(
            address(
                new ERC1967Proxy(
                    address(unstakeCooldownImpl),
                    abi.encodeWithSelector(CooldownBase.initialize.selector, owner, address(acm))
                )
            )
        );

        // 6. Deploy SUSCCCooldownRequestImpl and set implementation
        cooldownRequestImpl = new sUSCCCooldownRequestImpl(IERC4626(address(ezUSCC)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(ezUSCC);
        IUnstakeHandler[] memory impls = new IUnstakeHandler[](1);
        impls[0] = IUnstakeHandler(address(cooldownRequestImpl));
        unstakeCooldown.setImplementations(tokens, impls);

        // 7. Deploy SUSCCStrategy
        SUSCCStrategy strategyImpl = new SUSCCStrategy(IERC4626(address(ezUSCC)), IERC20(USDC));
        strategy = SUSCCStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl),
                    abi.encodeWithSelector(
                        SUSCCStrategy.initialize.selector,
                        owner,
                        address(acm),
                        address(cdo),
                        address(erc20Cooldown),
                        address(unstakeCooldown)
                    )
                )
            )
        );
        vm.label(address(strategy), "SUSCCStrategy");

        // 8. Deploy SUSCCAprPairProvider
        provider = new SUSCCAprPairProvider(IsUSDS(address(sUSDS)), IsUSCC(address(strategy)));
        feed = AprPairFeed(
            address(
                new ERC1967Proxy(
                    address(new AprPairFeed()),
                    abi.encodeWithSelector(
                        AprPairFeed.initialize.selector,
                        owner,
                        address(acm),
                        address(provider),
                        4 hours,
                        "USCC CDO APR Pair"
                    )
                )
            )
        );
        vm.label(address(feed), "AprPairFeed");

        // 9. Deploy Accounting
        Accounting accountingImpl = new Accounting();
        accounting = Accounting(
            address(
                new ERC1967Proxy(
                    address(accountingImpl),
                    abi.encodeWithSelector(
                        Accounting.initialize.selector, owner, address(acm), address(cdo), address(feed)
                    )
                )
            )
        );
        vm.label(address(accounting), "Accounting");

        // 10. Grant Roles
        _grantRole(PAUSER_ROLE, owner);
        _grantRole(UPDATER_STRAT_CONFIG_ROLE, owner);
        _grantRole(UPDATER_FEED_ROLE, owner);
        _grantRole(UPDATER_CDO_APR_ROLE, address(feed));
        _grantRole(COOLDOWN_WORKER_ROLE, address(strategy));
        _grantRole(COOLDOWN_WORKER_ROLE, address(owner));

        // 11. Configure CDO
        cdo.configure(
            IAccounting(address(accounting)),
            IStrategy(address(strategy)),
            ITranche(address(jrtVault)),
            ITranche(address(srtVault))
        );

        // 12. Enable actions on tranches
        cdo.setActionStates(address(jrtVault), true, true);
        cdo.setActionStates(address(srtVault), true, true);

        // 13. Set reserve basis points
        accounting.setReserveBps(0.02e18);

        erc20Cooldown.setCooldownDisabled(IERC20(address(ezUSCC)), true);
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

// Mock Role Manager
contract MockRoleManager is IRoleManager {
    mapping(address => bool) public isRebalanceAdminMap;
    mapping(address => bool) public isPauserMap;
    mapping(address => bool) public isExchangeRateAdminMap;

    function isRebalanceAdmin(address potentialAddress) external view override returns (bool) {
        return isRebalanceAdminMap[potentialAddress];
    }

    function isPauser(address potentialAddress) external view override returns (bool) {
        return isPauserMap[potentialAddress];
    }

    function isExchangeRateAdmin(address potentialAddress) external view override returns (bool) {
        return isExchangeRateAdminMap[potentialAddress];
    }

    // Helper functions for testing
    function setRebalanceAdmin(address addr, bool status) external {
        isRebalanceAdminMap[addr] = status;
    }

    function setPauser(address addr, bool status) external {
        isPauserMap[addr] = status;
    }

    function setExchangeRateAdmin(address addr, bool status) external {
        isExchangeRateAdminMap[addr] = status;
    }
}

contract MockWithdrawQueue is WithdrawQueue {}

// Dummy Delegate Strategy for testing - used to trigger _fillWithdrawQueue via manage()
contract DummyDelegateStrategy {
    // Returns 0 underlying value - no assets managed
    function underlyingValue(address) external pure returns (uint256) {
        return 0;
    }

    // No-op function that can be called via delegatecall from manage()
    function noop() external {}
}

contract MockSUSDS is IsUSDS {
    uint256 public ssrValue = 0; // 0% APR by default

    function ssr() external view override returns (uint256) {
        return ssrValue;
    }

    function rho() external view override returns (uint64) {
        return uint64(block.timestamp);
    }

    function setSSR(uint256 _ssr) external {
        ssrValue = _ssr;
    }
}

