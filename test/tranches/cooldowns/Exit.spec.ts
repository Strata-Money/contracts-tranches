import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { UTest } from 'atma-utest'
import { $usde } from '../utils/$usde';
import { $erc20 } from '../utils/$erc20';
import { $tranche } from '../utils/$tranche';
import { $hh } from '../utils/$hh';
import { $require } from 'dequanto/utils/$require';
import { $bigint } from 'dequanto/utils/$bigint';
import { $erc4626 } from '../utils/$erc4626';
import { $exitMode } from '@s/utils/$exitMode';
import { $date } from 'dequanto/utils/$date';
import { $ethena } from '../utils/$ethena';
import { $promise } from 'dequanto/utils/$promise';


let hh = new HardhatProvider();
let alice = await hh.deployer(1);

let {
    jrtVault,
    srtVault,
    strategy,
    erc20Cooldown,
    unstakeCooldown,
    sharesCooldown,
    accounting,
    cdo,
    USDe,
    sUSDe,
} = await $hh.test.deploy();

let {
    configManager
} = await $hh.test.factory.ensureConfigManager();


let {
    client,
    deployer
} = $hh.test;

await $erc20.mint(USDe, deployer, alice, 1e6);

//await strategy.$receipt().setCooldowns($hh.test.factory.accounts.timelock.admin, 0n, 0n);
await $ethena.setCooldownDuration(sUSDe, deployer, 0);
await accounting.$receipt().setMinimumJrtSrtRatio(deployer, $bigint.toWei(0.01))
await accounting.$receipt().setMinimumJrtSrtRatioBuffer(deployer, $bigint.toWei(0.01))


await $hh.test.factory.addRoles({
    [cdo.address]: [
        await sharesCooldown.COOLDOWN_WORKER_ROLE()
    ]
});

await $hh.test.snapshot('exit');

UTest.create({
    async $after () {
        await $hh.test.reset();
    },
     async $teardown () {
        await $hh.test.reset('exit');
    },
    async 'coverage checks' () {

        // Alice deposits into jrt and srt vaults
        await $usde.mint(USDe, alice, 1000.0);
        await $tranche.deposit(jrtVault, alice, USDe, 300.0);

        // Senior === 0, the coverage must be uint32.max
        let coverage = await cdo.coverage();
        $require.eq(coverage, 2 ** 32 - 1);

        // Senior === Junior, the coverage must be 100%
        await $tranche.deposit(srtVault, alice, USDe, 300.0);
        coverage = await cdo.coverage();
        $require.eq(coverage, 1e6);
    },
    async 'junior redemption' () {

        await $tranche.deposit(jrtVault, alice, USDe, 100.0);
        await $tranche.deposit(srtVault, alice, USDe, 100.0);

        await $exitMode.set(sharesCooldown, configManager, jrtVault.address, [
            { covPct: 5, feePct: 10, lock: $date.parseTimespan('1day', { get: 's' })  },
            { covPct: 10, feePct: 5, lock: $date.parseTimespan('8hours', { get: 's' })  },
            { covPct: 0, feePct: 1, lock: 0  },
        ]);

        await $hh.test.snapshot('exit-jrt');
        return UTest.create({
            async $teardown () {
                await $hh.test.reset('exit-jrt');
            },
            async 'should exit with 1% fee' () {
                await $util.ensureCoverage(20, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await jrtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(jrtVault, alice, shares);
                let fee = $bigint.toEther(assets) * .01;
                $require.eq(fee, 10 * 0.01, `Should accrue 1% fee`);
                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            },
            async 'should exit with 5% fee and 8hours shares-lock' () {
                await $util.ensureCoverage(8, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await jrtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(jrtVault, alice, shares);
                $require.eq(assetsFact, 0n);
                let fee = $bigint.toEther(assets) * .05;

                await client.debug.mine('1hour');
                let { error } = await $promise.caught(sharesCooldown.$receipt().finalize(alice, jrtVault.address, alice.address));
                $require.match(/NothingToFinalize/, error?.message);

                await client.debug.mine('8hours');
                let assetsBefore = await USDe.balanceOf(alice.address);
                await sharesCooldown.$receipt().finalize(alice, jrtVault.address, alice.address);
                assetsFact = await USDe.balanceOf(alice.address) - assetsBefore;

                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            },
            async 'should exit with 10% fee and 1day shares-lock' () {
                await $util.ensureCoverage(4, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await jrtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(jrtVault, alice, shares);
                $require.eq(assetsFact, 0n);
                let fee = $bigint.toEther(assets) * .10;

                await client.debug.mine('1hour');
                let { error } = await $promise.caught(sharesCooldown.$receipt().finalize(alice, jrtVault.address, alice.address));
                $require.match(/NothingToFinalize/, error?.message);

                await client.debug.mine('1day');
                let assetsBefore = await USDe.balanceOf(alice.address);
                await sharesCooldown.$receipt().finalize(alice, jrtVault.address, alice.address);
                assetsFact = await USDe.balanceOf(alice.address) - assetsBefore;

                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            }
        })
    },
    async 'senior redemption' () {

        await $tranche.deposit(jrtVault, alice, USDe, 100.0);
        await $tranche.deposit(srtVault, alice, USDe, 100.0);

        await $exitMode.set(sharesCooldown, configManager, srtVault.address, [
            { covPct: 5, feePct: 10, lock: $date.parseTimespan('1day', { get: 's' })  },
            { covPct: 10, feePct: 5, lock: $date.parseTimespan('8hours', { get: 's' })  },
            { covPct: 0, feePct: 1, lock: 0  },
        ]);

        await $hh.test.snapshot('exit-srt');
        return UTest.create({
            async $teardown () {
                await $hh.test.reset('exit-srt');
            },
            async 'should exit with 1% fee' () {
                await $util.ensureCoverage(20, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await srtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(srtVault, alice, shares);
                let fee = $bigint.toEther(assets) * .01;
                $require.eq(fee, 10 * 0.01, `Should accrue 1% fee`);
                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            },
            async 'should exit with 5% fee and 8hours shares-lock' () {
                await $util.ensureCoverage(8, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await srtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(srtVault, alice, shares);
                $require.eq(assetsFact, 0n);
                let fee = $bigint.toEther(assets) * .05;

                await client.debug.mine('1hour');
                let { error } = await $promise.caught(sharesCooldown.$receipt().finalize(alice, srtVault.address, alice.address));
                $require.match(/NothingToFinalize/, error?.message);

                await client.debug.mine('8hours');
                let assetsBefore = await USDe.balanceOf(alice.address);
                await sharesCooldown.$receipt().finalize(alice, srtVault.address, alice.address);
                assetsFact = await USDe.balanceOf(alice.address) - assetsBefore;

                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            },
            async 'should exit with 10% fee and 1day shares-lock' () {
                await $util.ensureCoverage(4, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await srtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(srtVault, alice, shares);
                $require.eq(assetsFact, 0n);
                let fee = $bigint.toEther(assets) * .10;

                await client.debug.mine('1hour');
                let { error } = await $promise.caught(sharesCooldown.$receipt().finalize(alice, srtVault.address, alice.address));
                $require.match(/NothingToFinalize/, error?.message);

                await client.debug.mine('1day');
                let assetsBefore = await USDe.balanceOf(alice.address);
                await sharesCooldown.$receipt().finalize(alice, srtVault.address, alice.address);
                assetsFact = await USDe.balanceOf(alice.address) - assetsBefore;

                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            }
        })
    },
    async 'should use old exit fee flow' () {
        await $tranche.deposit(jrtVault, alice, USDe, 100.0);
        await $tranche.deposit(srtVault, alice, USDe, 100.0);

        await $hh.test.snapshot('exit-old-fee');
        return UTest.create({
            async $teardown () {
                await $hh.test.reset('exit-old-fee');
            },
            async 'when no lockup bounds' () {
                await $exitMode.set(sharesCooldown, configManager, srtVault.address, [
                    { covPct: 0, feePct: 0, lock: 0  },
                    { covPct: 0, feePct: 0, lock: 0  },
                    { covPct: 0, feePct: 0, lock: 0  },
                ]);
                await cdo.$receipt().setExitFees({
                    address: configManager.address,
                    type: 'impersonated'
                }, BigInt(0.003e18), BigInt(0.003e18));

                await $util.ensureCoverage(20, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await srtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(srtVault, alice, shares);
                let fee = $bigint.toEther(assets) * .003;
                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            },
            async 'when empty default bound' () {
                await $exitMode.set(sharesCooldown, configManager, srtVault.address, [
                    { covPct: 10, feePct: 2, lock: 60  },
                    { covPct: 30, feePct: 0, lock: 120  },
                    { covPct: 0, feePct: 0, lock: 0  },
                ]);
                await cdo.$receipt().setExitFees({
                    address: configManager.address,
                    type: 'impersonated'
                }, BigInt(0.0025e18), BigInt(0.0025e18));

                await $util.ensureCoverage(60, { jrt: 1000.0 });
                let shares = BigInt(10e18);
                let assets = await srtVault.convertToAssets(shares);
                let assetsFact = await $erc4626.redeem(srtVault, alice, shares);
                let fee = $bigint.toEther(assets) * .0025;
                $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
            }
        })
    },
    async 'should early exit the shares cooldown' () {
        await $tranche.deposit(jrtVault, alice, USDe, 100.0);
        await $tranche.deposit(srtVault, alice, USDe, 100.0);

        await $exitMode.set(sharesCooldown, configManager, jrtVault.address, [
            { covPct: 70, feePct: 0, lock: $date.parseTimespan('8days', { get: 's' })  },
        ]);
        await sharesCooldown.$receipt().setVaultEarlyExitFee(deployer, jrtVault.address, BigInt(0.01e18));

        let amount = BigInt(10e18);
        let assets = await jrtVault.convertToAssets(amount);
        let assetsFact = await $erc4626.redeem(jrtVault, alice, 10.0);
        $require.eq(assetsFact, 0n);


        let balanceBefore = await USDe.balanceOf(alice.address);
        await sharesCooldown.$receipt().finalizeWithFee(alice, jrtVault.address, alice.address, 0n);

        assetsFact = await USDe.balanceOf(alice.address) - balanceBefore;

        let fee = $bigint.toEther(assets) * 0.01 * 8;
        $require.eq($bigint.toEther(assetsFact) + fee, $bigint.toEther(assets));
    },

    async 'should revert on exit when coverage is below minimumJrtSrtRatio' () {
        await $tranche.deposit(jrtVault, alice, USDe, 100.0);
        await $tranche.deposit(srtVault, alice, USDe, 100.0);

        await $exitMode.set(sharesCooldown, configManager, jrtVault.address, [
            { covPct: 1,  feePct: 2  , lock: $date.parseTimespan('8days', { get: 's' })  },
            { covPct: 70, feePct: 1.5, lock: $date.parseTimespan('8days', { get: 's' })  },
        ]);

        let assetsFact = await $erc4626.redeem(jrtVault, alice, 10.0);
        $require.eq(assetsFact, 0n);

        await accounting.$receipt().setMinimumJrtSrtRatioBuffer(deployer, BigInt(1.10e18));
        await accounting.$receipt().setMinimumJrtSrtRatio(deployer, BigInt(1.10e18));
        await client.debug.mine('10days');

        // new redemption should fail
        let { error } = await $promise.caught($erc4626.redeem(jrtVault, alice, 10.0));
        $require.match(/ERC4626ExceededMaxRedeem/, error.message);

        // finalization works
        let before = await USDe.balanceOf(alice.address);
        await sharesCooldown.$receipt().finalize(alice, jrtVault.address, alice.address);
        let received = $bigint.toEther(await USDe.balanceOf(alice.address) - before);

        $require.eq(received, 10 - 10 * 0.015);
    }
})


namespace $util {
    export async function ensureCoverage (cov: number, minimums?: { jrt?: number, srt?: number }) {
        let { jrtNav, srtNav } = await cdo.totalAssetsUnlocked();
        let jrtNavEth = $bigint.toEther(jrtNav);
        let srtNavEth = $bigint.toEther(srtNav);

        let current = jrtNavEth / srtNavEth * 100;
        if (current < cov) {
            let amount = cov / 100 * srtNavEth - jrtNavEth;
            await $erc4626.deposit(jrtVault, alice, $bigint.toWei(amount));
            jrtNavEth += amount;
        } else if (current > cov) {
            let amount = jrtNavEth  * 100 / cov - srtNavEth;
            await $erc4626.deposit(srtVault, alice, $bigint.toWei(amount));
            srtNavEth += amount;
        }

        let scale = 1;
        if (minimums?.jrt > jrtNavEth) {
            scale = minimums.jrt / jrtNavEth;
        }
        if (minimums?.srt > srtNavEth) {
            scale = Math.max(scale, minimums.srt / srtNavEth);
        }
        if (scale > 1) {
            await $erc4626.deposit(jrtVault, alice, $bigint.toWei(jrtNavEth * scale - jrtNavEth));
            await $erc4626.deposit(srtVault, alice, $bigint.toWei(srtNavEth * scale - srtNavEth));
        }
    }
}
