import memd from 'memd';
import { AccessControlManager } from '@0xc/hardhat/AccessControlManager/AccessControlManager'
import { MockStakedUSDe } from '@0xc/hardhat/MockStakedUSDe/MockStakedUSDe'
import { MockUSDe } from '@0xc/hardhat/MockUSDe/MockUSDe'
import { Tranche } from '@0xc/hardhat/Tranche/Tranche'
import { Web3Client } from 'dequanto/clients/Web3Client'
import { Deployments } from 'dequanto/contracts/deploy/Deployments'
import { TEth } from 'dequanto/models/TEth'
import { Platforms } from '../platforms/Platforms'
import { IPlatform, IPlatformAccounts } from '../platforms/IPlatform'
import { $require } from 'dequanto/utils/$require'
import { SUSDeStrategy } from '@0xc/hardhat/sUSDeStrategy/sUSDeStrategy'
import { StrataCDO } from '@0xc/hardhat/StrataCDO/StrataCDO'
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown'
import { UnstakeCooldown } from '@0xc/hardhat/UnstakeCooldown/UnstakeCooldown'
import { Accounting } from '@0xc/hardhat/Accounting/Accounting'
import { Tranches } from '../platforms/Tranches'
import { $address } from 'dequanto/utils/$address'
import { IERC4626 } from 'dequanto/prebuilt/openzeppelin/IERC4626'
import { $contract } from 'dequanto/utils/$contract'
import { SUSDeCooldownRequestImpl } from '@0xc/hardhat/sUSDeCooldownRequestImpl/sUSDeCooldownRequestImpl';
import { $date } from 'dequanto/utils/$date';
import { AprPairFeed } from '@0xc/hardhat/AprPairFeed/AprPairFeed';
import { SUSDeAprPairProvider } from '@0xc/hardhat/sUSDeAprPairProvider/sUSDeAprPairProvider';
import { MockStakedUSDS } from '@0xc/hardhat/MockStakedUSDS/MockStakedUSDS';
import { $erc4626 } from '../../test/tranches/utils/$erc4626';
import { TrancheDepositor } from '@0xc/hardhat/TrancheDepositor/TrancheDepositor';
import { SafeTx } from 'dequanto/safe/SafeTx';
import { InMemoryServiceTransport } from 'dequanto/safe/transport/InMemoryServiceTransport';
import { l } from 'dequanto/utils/$logger';
import { Addresses } from '@s/constants';
import { MockERC4626 } from '@0xc/hardhat/MockERC4626/MockERC4626';
import { AaveAprPairProvider } from '@0xc/hardhat/AaveAprPairProvider/AaveAprPairProvider';
import { CDOLens } from '@0xc/hardhat/CDOLens/CDOLens';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { ContractBase } from 'dequanto/contracts/ContractBase';
import { Constructor } from 'dequanto/utils/types';


export class TranchesDeployments {

    ds: Deployments
    platform: IPlatform
    owner: TEth.IAccount
    deployer: TEth.EoAccount
    client: Web3Client
    ethenaInfo: typeof Tranches.ethena;

    accounts: IPlatformAccounts

    constructor(params: {
        client: Web3Client
        deployer: TEth.EoAccount
        owner?: TEth.IAccount
        accounts?: IPlatformAccounts
        deployments?: 'throw' | 'redeploy'
    }) {
        this.deployer = params.deployer;
        this.owner = params.owner ?? params.deployer;
        this.client = params.client;
        this.platform = Platforms[params.client.network];
        this.accounts = params.accounts;

        this.ds = new Deployments(params.client, params.deployer, {
            directory: './deployments/',
            whenBytecodeChanged: params.deployments ?? (this.isTestnet() ? null : 'throw'),
            fork: params.client.forked?.platform
        });

        let info = JSON.parse(JSON.stringify(Tranches.ethena)) as typeof Tranches.ethena;

        if (this.platform.Tranches?.ethena) {
            info.jrt = { ...info.jrt, ...(this.platform.Tranches.ethena.jrt ?? {}) } as any;
            info.srt = { ...info.srt, ...(this.platform.Tranches.ethena.srt ?? {}) } as any;
        }
        this.ethenaInfo = info;
    }

    async get<T extends ContractBase>(Ctor: Constructor<T>, params?: { id?: 'jrUSDe' | 'srUSDe', cdo?: 'USDe' }) {
        if (params?.id === 'jrUSDe') {
            return await this.ds.get(Ctor, { id: 'USDeJrt' })
        }
        if (params?.id === 'srUSDe') {
            return await this.ds.get(Ctor, { id: 'USDeSrt' })
        }
        let all = await this.ds.store.getDeployments();
        let byName = all.filter(d => d.name === Ctor.name);
        $require.gt(byName.length, 0, `${Ctor.name} not found in deployments`);

        if (byName.length === 1) {
            return await this.ds.get(Ctor, { id: byName[0].id });
        }
        let cdo = params?.cdo ?? 'USDe';
        let byCdo = byName.filter(x => x.id.toLowerCase().includes(cdo.toLowerCase()));
        if (byCdo.length === 1) {
            return await this.ds.get(Ctor, { id: byCdo[0].id });
        }

        if (byCdo.length === 0) {
            throw new Error(`No ${Ctor.name} found for CDO ${cdo} in deployments`);
        }
        if (byCdo.length > 1) {
            throw new Error(`Multiple ${Ctor.name} found for CDO ${cdo}: ${byCdo.map(x => x.id).join(', ')}`);
        }
    }

    @memd.deco.memoize()
    async ensureEthena() {
        let network = this.ds.client.network;
        if (network === 'hardhat') {
            let USDe = await this.ds.ensureContract(MockUSDe);
            let sUSDe = await this.ds.ensureContract(MockStakedUSDe, {
                arguments: [
                    USDe.address,
                    this.owner.address,
                    this.owner.address
                ]
            });
            let sUSDS = await this.ds.ensureContract(MockStakedUSDS, {
                arguments: [
                    USDe.address,
                ]
            });
            let pUSDe = await this.ds.ensureContract(MockERC4626, {
                id: 'pUSDeMock',
                arguments: [USDe.address]
            });
            await sUSDe.$receipt().setCooldownDuration(this.owner, $date.parseTimespan('1week', { get: 's' }));

            return { USDe, sUSDe, sUSDS, pUSDe, };
        }
        if (network === 'hoodi') {
            let USDeAddress = $require.Address(this.platform.Tokens['USDe'].address);
            let sUSDeAddress = $require.Address(this.platform.Tokens['sUSDe'].address);
            let pUSDeAddress = $require.Address(this.platform.Tokens['pUSDe'].address);
            let sUSDS = await this.ds.ensureContract(MockStakedUSDS, {
                arguments: [
                    USDeAddress,
                ]
            });
            return {
                USDe: new MockUSDe(USDeAddress, this.ds.client),
                sUSDe: new MockStakedUSDe(sUSDeAddress, this.ds.client),
                sUSDS: sUSDS,
                pUSDe: new MockERC4626(pUSDeAddress, this.ds.client)
            };
        }

        let USDeAddress = $require.Address(this.platform.Tokens['USDe'].address);
        let sUSDeAddress = $require.Address(this.platform.Tokens['sUSDe'].address);
        let sUSDSAddress = $require.Address(this.platform.Tokens['sUSDS'].address);
        let pUSDeAddress = $require.Address(this.platform.Tokens['pUSDe'].address);
        return {
            USDe: new MockUSDe(USDeAddress, this.ds.client),
            sUSDe: new MockStakedUSDe(sUSDeAddress, this.ds.client),
            sUSDS: new MockStakedUSDS(sUSDSAddress, this.ds.client),
            pUSDe: new MockERC4626(pUSDeAddress, this.ds.client)
        };
    }

    @memd.deco.memoize()
    async ensureACM() {
        const owner = this.owner!;
        const acm = await this.ds.ensureContract(AccessControlManager, {
            arguments: [owner.address]
        });

        if (this.isTestnet() === false) {
            let ownerIsAdmin = await acm.hasRole('0x', owner.address);
            let deployer = this.deployer;
            await this.ds.configure(acm, {
                title: `Grant Owner the AccessControlManager Admin Role`,
                shouldUpdate: ownerIsAdmin === false,
                async updater() {
                    await acm.$receipt().grantRole(deployer, '0x', owner.address);
                    await acm.$receipt().revokeRole(owner, '0x', deployer.address);
                }
            });
            let deployerIsAdmin = await acm.hasRole('0x', deployer.address);
            await this.ds.configure(acm, {
                title: `Revoke Deployer the AccessControlManager Admin Role`,
                shouldUpdate: deployerIsAdmin && $address.eq(deployer.address, owner.address) === false,
                async updater() {
                    await acm.$receipt().revokeRole(owner, '0x', deployer.address);
                }
            });
        }
        return acm;
    }

    async ensureRole(role: TEth.Hex, account: TEth.Address) {
        let acm = await this.ensureACM();
        let has = await acm.hasRole(role, account);
        if (has === false) {
            await acm.$receipt().grantRole(this.owner, role, account);
        }
    }
    async ensureRoles(roles: Record<string, Record<TEth.Address, boolean>>) {
        const acm = await this.ensureACM();
        const admin = this.owner;
        for (let role in roles) {
            for (let address in roles[role]) {
                await ensure(role, address as TEth.Address, roles[role][address]);
            }
        }

        async function ensure(role: string, address: TEth.Address, has: boolean) {
            let roleHash = role.startsWith('0x')
                ? role as TEth.Hex
                : $contract.keccak256(role);
            let hasCurrent = await acm.hasRole(roleHash, address);
            if (hasCurrent !== has) {
                l`gray<EnsureRole>: cyan<${role}> ${has ? '🟢' : '🔴'} cyan<${address}> ⌛`;
                if (has) {
                    await acm.$receipt().grantRole(admin, roleHash, address)
                } else {
                    await acm.$receipt().revokeRole(admin, roleHash, address)
                }
            }
        }
    }

    async addRoles() {
        let roles = {
            [this.owner.address]: [
                $contract.keccak256('PAUSER_ROLE'),
                $contract.keccak256('UPDATER_STRAT_CONFIG_ROLE'),
                $contract.keccak256('UPDATER_FEED_ROLE'),
                $contract.keccak256('RESERVE_MANAGER_ROLE'),
            ]
        };
        for (let account in roles) {
            for (let role of roles[account]) {
                await this.ensureRole(role, account as TEth.Address);
            }
        }
    }

    async ensureEthenaTranches(cdo: StrataCDO) {
        const { USDe, sUSDe } = await this.ensureEthena();

        const acm = await this.ensureACM();
        const info = this.ethenaInfo;
        let { contract: jrtVault } = await this.ds.ensureWithProxy(Tranche, {
            id: 'USDeJrt',
            initialize: [
                this.owner.address,
                acm.address,
                info.jrt.name,
                info.jrt.symbol,
                USDe.address,
                cdo.address,
            ]
        });
        let { contract: srtVault } = await this.ds.ensureWithProxy(Tranche, {
            id: 'USDeSrt',
            initialize: [
                this.owner.address,
                acm.address,
                info.srt.name,
                info.srt.symbol,
                USDe.address,
                cdo.address,
            ]
        });

        return {
            jrtVault: jrtVault as Tranche & IERC4626,
            srtVault: srtVault as Tranche & IERC4626,
        };
    }

    async ensureConfigManager() {
        let { cdo, acm } = await this.ensureEthenaCDO();
        let owner = this.accounts.timelock.admin;
        let { contract: configManager } = await this.ds.ensureWithProxy(TwoStepConfigManager, {
            id: 'USDeConfigManager',
            arguments: [cdo.address],
            initialize: []
        });

        await this.ds.configure(cdo, {
            title: `Set Two-Step Config Manager`,
            async shouldUpdate() {
                    return $address.eq(await cdo.twoStepConfigManager(), configManager.address) === false
            },
            async updater() {
                await cdo.$receipt().setTwoStepConfigManager(owner, configManager.address);
            }
        });

        await this.ensureRoles({
            'PROPOSER_CONFIG_ROLE': {
                [this.accounts.safe.admin.address]: true
            },
            'UPDATER_STRAT_CONFIG_ROLE': {
                [this.accounts.timelock.config.address]: true
            }
        });

        return { configManager };
    }

    @memd.deco.memoize()
    async ensureCooldowns() {
        const acm = await this.ensureACM();
        const { contract: erc20Cooldown } = await this.ds.ensureWithProxy(ERC20Cooldown, {
            initialize: [
                this.owner.address,
                acm.address
            ]
        });
        const { contract: unstakeCooldown } = await this.ds.ensureWithProxy(UnstakeCooldown, {
            initialize: [
                this.owner.address,
                acm.address
            ]
        });

        let { sUSDe } = await this.ensureEthena();
        const { contractBeaconProxy: sUSDeCooldownRequestImpl } = await this.ds.ensureWithBeacon(SUSDeCooldownRequestImpl, {
            //const { contract: sUSDeCooldownRequestImpl } = await this.ds.ensureWithProxy(SUSDeCooldownRequestImpl, {
            id: 'SUSDeCooldownRequestBeacon',
            arguments: [sUSDe.address],
            initialize: [$address.ZERO, $address.ZERO]
        });

        await this.ds.configure(unstakeCooldown, {
            shouldUpdate: async () => {
                let impl = await unstakeCooldown.implementations(sUSDe.address);
                return $address.eq(impl, sUSDeCooldownRequestImpl.address) === false
            },
            updater: async () => {
                await unstakeCooldown.$receipt().setImplementations(this.owner, [sUSDe.address], [sUSDeCooldownRequestImpl.address]);
            }
        });

        return {
            erc20Cooldown,
            unstakeCooldown,
            acm,
        };
    }

    async ensureFeeds() {
        const acm = await this.ensureACM();
        const { sUSDe, USDe, sUSDS } = await this.ensureEthena();
        const { contract: sUSDeAprPairProvider } = await this.ds.ensure(SUSDeAprPairProvider, {
            arguments: [
                sUSDS.address,
                sUSDe.address,
            ]
        });
        let CURRENT_PROVIDER = sUSDeAprPairProvider.address;
        let aaveAprPairProvider: AaveAprPairProvider;

        const network = this.client.network;
        const aavePool = Addresses[network]?.AavePool;
        if (aavePool) {
            const { contract } = await this.ds.ensure(AaveAprPairProvider, {
                arguments: [
                    $require.Address(Addresses[network].AavePool),
                    [
                        $require.Address(Addresses[network].USDC),
                        $require.Address(Addresses[network].USDT),
                    ],
                    sUSDe.address
                ]
            });
            aaveAprPairProvider = contract;
            CURRENT_PROVIDER = aaveAprPairProvider.address;
        }

        const stalePeriodAfter = $date.parseTimespan(this.platform.Feed.stalePeriodAfter, { get: 's' });
        const { contract: feed } = await this.ds.ensureWithProxy(AprPairFeed, {
            id: 'sUSDeAprFeeds',
            initialize: [
                this.owner.address,
                acm.address,
                sUSDeAprPairProvider.address,
                BigInt(stalePeriodAfter),
                "Ethena CDO APR Pair"
            ]
        });

        await this.ds.configure(feed, {
            title: 'Update AprPair Feed Provider',
            shouldUpdate: async () => {
                let providerAddress = await feed.provider();
                return !$address.eq(providerAddress, CURRENT_PROVIDER);
            },
            updater: async () => {
                await feed.$receipt().setProvider(this.owner, CURRENT_PROVIDER)
            }
        });

        return {
            feed,
            sUSDeAprPairProvider,
            aaveAprPairProvider,
        };
    }

    @memd.deco.memoize()
    async ensureEthenaCDO() {
        const { USDe, sUSDe, pUSDe, } = await this.ensureEthena();

        const acm = await this.ensureACM();
        const info = this.ethenaInfo;

        const { contract: cdo } = await this.ds.ensureWithProxy(StrataCDO, {
            id: 'USDeCDO',
            arguments: [],
            initialize: [
                this.owner.address,
                acm.address,
            ]
        });

        // Strategy
        const { erc20Cooldown, unstakeCooldown } = await this.ensureCooldowns();

        const { contract: strategy } = await this.ds.ensureWithProxy(SUSDeStrategy, {
            arguments: [
                sUSDe.address
            ],
            initialize: [
                this.owner.address,
                acm.address,
                cdo.address,
                erc20Cooldown.address,
                unstakeCooldown.address
            ]
        });
        await this.ensureRole(await erc20Cooldown.COOLDOWN_WORKER_ROLE(), strategy.address)


        // Accounting
        const accounting = await this.ensureAccounting(cdo.address);

        // Oracle
        const { feed, sUSDeAprPairProvider } = await this.ensureFeeds();


        const { jrtVault, srtVault } = await this.ensureEthenaTranches(cdo);

        await this.ds.configure(cdo, {
            shouldUpdate: async () => $address.eq(await cdo.strategy(), $address.ZERO),
            updater: async (x, value) => {
                await cdo.$receipt().configure(
                    this.owner,
                    accounting.address,
                    strategy.address,
                    jrtVault.address,
                    srtVault.address
                );
            },
        });

        const output = {
            acm,
            jrtVault,
            srtVault,
            cdo,
            strategy,
            accounting,
            erc20Cooldown,
            unstakeCooldown,
            feed,
            USDe,
            sUSDe,
            sUSDeAprPairProvider,
            pUSDe,
        };

        await this.configure(info, output);
        return output;
    }

    async ensureAccounting(cdo: TEth.Address) {
        const acm = await this.ensureACM();
        const { feed } = await this.ensureFeeds();
        const { contract: accounting } = await this.ds.ensureWithProxy(Accounting, {
            id: `USDeAccounting`,
            initialize: [
                this.owner.address,
                acm.address,
                cdo,
                feed.address,
            ]
        });
        return accounting;
    }

    async configure(info: typeof Tranches['ethena'], contracts: {
        acm: AccessControlManager,
        jrtVault: Tranche,
        srtVault: Tranche,
        cdo: StrataCDO,
        strategy: SUSDeStrategy,
        accounting: Accounting,
        feed: AprPairFeed
    }) {

        let {
            acm,
            jrtVault,
            srtVault,
            cdo,
            strategy,
            accounting,
            feed,
        } = contracts;

        await this.addRoles();

        await this.ensureRole($contract.keccak256('UPDATER_CDO_APR_ROLE'), feed.address);
        await this.setCooldown(strategy, info);

        if (await jrtVault.totalSupply() === 0n) {
            if (this.client.network === 'eth') {
                throw new Error(`Already deployed`);
                await this.initialDepositAtomic({ jrtVault, srtVault, cdo });
            } else {
                //await this.initialDeposit({ jrtVault, srtVault, cdo });
            }
        }

        await this.setTrancheActions(cdo, jrtVault, info, 'jrt');
        await this.setTrancheActions(cdo, srtVault, info, 'srt');
    }

    async setTrancheActions(cdo: StrataCDO, tranche: Tranche, info: typeof Tranches['ethena'], type: 'srt' | 'jrt') {
        let actions = type === 'jrt'
            ? await cdo.actionsJrt()
            : await cdo.actionsSrt();

        let current = type === 'jrt'
            ? info.jrt
            : info.srt;

        if (actions.isDepositEnabled !== current.depositsEnabled || actions.isWithdrawEnabled !== current.withdrawalsEnabled) {
            await cdo.$receipt().setActionStates(
                this.owner,
                tranche.address,
                current.depositsEnabled,
                current.withdrawalsEnabled,
            );
        }
    }

    async setCooldown(strategy: SUSDeStrategy, info: typeof Tranches['ethena']) {
        let cooldowns = [info.jrt.sUSDeCooldown, info.srt.sUSDeCooldown]
            .map(mix => {
                if (typeof mix === 'string') {
                    return $date.parseTimespan(mix, { get: 's' });
                }
                return mix;
            })
            .map(BigInt);


        let current = await Promise.all([
            await strategy.sUSDeCooldownJrt(),
            await strategy.sUSDeCooldownSrt(),
        ]);
        await this.ds.configure(strategy, {
            shouldUpdate: () => {
                return cooldowns[0] !== current[0] || cooldowns[1] !== current[1]
            },
            updater: async () => {
                await strategy.$receipt().setCooldowns(
                    this.owner,
                    cooldowns[0],
                    cooldowns[1]
                );
            }
        });
    }

    private async initialDeposit(tranches: { jrtVault: Tranche, srtVault: Tranche, cdo: StrataCDO }) {
        let { USDe } = await this.ensureEthena();
        let { jrtVault, srtVault, cdo } = tranches;

        if (this.owner.type === 'safe') {
            throw new Error(`Mainnet deployment not ready`);
        }
        const AMOUNT = 20n * 10n ** 18n;
        let balance = await USDe.balanceOf(this.owner.address);
        if (balance < AMOUNT) {
            if (this.client.network === 'hardhat' || this.client.network === 'hoodi') {
                await USDe.$receipt().mint(this.owner, this.owner.address, AMOUNT * 100n);
            } else {
                throw new Error(`Not enough balance for initial deposit.`);
            }
        }

        await cdo.$receipt().setActionStates(
            this.owner,
            $address.ZERO,
            true,
            false,
        );
        await $erc4626.deposit(jrtVault as any, this.owner, AMOUNT / 2n);
        await $erc4626.deposit(srtVault as any, this.owner, AMOUNT / 2n);
        await cdo.$receipt().setActionStates(
            this.owner,
            $address.ZERO,
            false,
            false,
        );
    }
    private async initialDepositAtomic(tranches: { jrtVault: Tranche, srtVault: Tranche, cdo: StrataCDO }) {
        let { USDe } = await this.ensureEthena();
        let { jrtVault, srtVault, cdo } = tranches;


        const AMOUNT = 40n * 10n ** 18n;
        let balance = await USDe.balanceOf(this.owner.address);
        if (balance < AMOUNT) {
            throw new Error(`Not enough balance for initial deposit.`);
        }

        const AMOUNT_SRT = AMOUNT / 2n;
        const AMOUNT_JRT = AMOUNT / 2n;

        let actions = [
            await cdo.$data().setActionStates(this.owner, $address.ZERO, true, false),

            await USDe.$data().approve(this.owner, jrtVault.address, AMOUNT_JRT),
            await jrtVault.$data().deposit(this.owner, AMOUNT_JRT, this.owner.address),

            await USDe.$data().approve(this.owner, srtVault.address, AMOUNT_SRT),
            await srtVault.$data().deposit(this.owner, AMOUNT_SRT, this.owner.address),

            await cdo.$data().setActionStates(this.owner, $address.ZERO, false, false),

        ];

        let safeTx = new SafeTx(this.owner, this.client, {
            safeTransport: new InMemoryServiceTransport(this.client, this.deployer)
        });

        l`yellow<Execute batch>`
        let tx = await safeTx.executeBatch(
            ...actions
        );
        await tx.wait();
    }

    async ensureDepositor() {
        let acm = await this.ensureACM();
        let { pUSDe } = await this.ensureEthena();
        let { cdo, jrtVault, USDe } = await this.ensureEthenaCDO();
        let { contract: depositor } = await this.ds.ensureWithProxy(TrancheDepositor, {
            id: 'TrancheDepositorV2',
            initialize: [
                this.owner.address,
                acm.address
            ]
        });


        await this.ensureRole($contract.keccak256('DEPOSITOR_CONFIG_ROLE'), this.owner.address);

        let status = await depositor.tranches(jrtVault.address, USDe.address);
        if (status == false) {
            await depositor.$receipt().addCdo(this.owner, cdo.address);
        }

        if (pUSDe) {
            let status = await depositor.autoWithdrawals(pUSDe.address);
            if (status === false) {
                await depositor.$receipt().addAutoWithdrawals(this.owner, [pUSDe.address], [true]);
            }
        }
        return depositor;
    }

    public isTestnet() {
        return this.client.platform !== 'eth';
    }

    async ensureLenses() {
        let { contract: cdoLens } = await this.ds.ensureWithProxy(CDOLens, {
            initialize: [
                this.owner.address
            ]
        });
    }
}
