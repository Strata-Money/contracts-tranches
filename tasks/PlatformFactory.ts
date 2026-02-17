import { TranchesDeployments } from '@s/deployments/TranchesDeployments';
import { IPlatformAccounts } from '@s/platforms/IPlatform';
import { ChainAccountService } from 'dequanto/ChainAccountService';
import { Web3Client } from 'dequanto/clients/Web3Client';
import { Web3ClientFactory } from 'dequanto/clients/Web3ClientFactory';
import { Config } from 'dequanto/config/Config';
import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { EoAccount } from 'dequanto/models/TAccount';
import { TEth } from 'dequanto/models/TEth';
import { InMemoryServiceTransport } from 'dequanto/safe/transport/InMemoryServiceTransport';
import { TxWriter } from 'dequanto/txs/TxWriter';
import { $require } from 'dequanto/utils/$require';

export namespace PlatformFactory {
    export async function init(params?: {
        deployments: 'throw' | 'redeploy'
    }) {
        const hh = new HardhatProvider();
        const config = await Config.fetch({
            configGlobal: './config/*.yml',
        });
        const platform = config.$get('chain') ?? 'hardhat';
        const client = await Web3ClientFactory.getAsync(platform);


const accounts = await getAccounts(client);

        if (accounts.safe?.admin.type === 'safe') {
            TxWriter.defaultOptions({
                safeTransport: new InMemoryServiceTransport(client, accounts.deployer as EoAccount)
            });
        }

        const depl = new TranchesDeployments({
            client,
            deployer: accounts.deployer as EoAccount,
            owner: accounts.timelock.admin,
            deployments: params?.deployments,
            accounts
        });
        return {
            tranches: depl,
            client,
            owner: accounts.timelock.admin,
            deployer: accounts.deployer,
        }
    }

    async function getAccounts (client: Web3Client) {
        const { platform, network } = client;
        const hh = new HardhatProvider();

        let deployer = await ChainAccountService.get(`${network}/deployer`);
        let timelockAdmin = await ChainAccountService.get(`timelock/${network}/strata`);
        let timelockConfig = await ChainAccountService.get(`timelock/${network}/config`);
        let safeAdmin = await ChainAccountService.get(`safe/${network}/strata`);
        let safeOperator = await ChainAccountService.get(`safe/${network}/owner`);

        if (network === 'hardhat') {
            deployer = hh.deployer(0);
            timelockAdmin = deployer;
            timelockConfig = deployer;
            safeAdmin = deployer;
            safeOperator = deployer;
        }

        if (platform !== 'eth') {
            safeAdmin ??= deployer;
            safeOperator ??= deployer;
            timelockAdmin ??= safeAdmin;
            timelockConfig ??= safeOperator;
        }

         if (platform === 'hardhat' && client.forked?.platform) {
            // Impersonate safe and timelock accounts in forked networks
            safeAdmin = {
                name: 'impersonated',
                type: 'eoa',
                address: safeAdmin.address,
            };
            safeOperator = {
                name: 'impersonated',
                type: 'eoa',
                address: safeOperator.address,
            };
            timelockAdmin = {
                name: 'impersonated',
                type: 'eoa',
                address: timelockAdmin.address,
            };
            timelockConfig = {
                name: 'impersonated',
                type: 'eoa',
                address: timelockConfig.address,
            };
            //await client.debug.impersonateAccount(owner.address);
        }

        return {
            deployer,
            safe: {
                admin: safeAdmin,
                operator: safeOperator,
            },
            timelock: {
                admin: timelockAdmin,
                config: timelockConfig,
            },
        } as IPlatformAccounts
    }
}
