import { HardhatProvider } from 'dequanto/hardhat/HardhatProvider';
import { UAction } from 'atma-utest'
import { $usde } from '../utils/$usde';
import { $erc20 } from '../utils/$erc20';
import { $acc } from '../utils/$acc';
import { TEth } from 'dequanto/models/TEth';
import { ERC20Cooldown } from '@0xc/hardhat/ERC20Cooldown/ERC20Cooldown';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { $date } from 'dequanto/utils/$date';
import { $require } from 'dequanto/utils/$require';
import { $hh } from '../utils/$hh';
import { $testCooldown } from './$testCooldown';
import { $promise } from 'dequanto/utils/$promise';
import { l } from 'dequanto/utils/$logger';


const _7DAYS = BigInt(7 * 24 * 60 * 60);

let hh = new HardhatProvider();
let alice = await hh.deployer(1);
let bob = await hh.deployer(2);

await $hh.test.deploy();

let { USDe, sUSDe } = await $hh.test.factory.ensureEthena();
let { erc20Cooldown, acm } = await $hh.test.factory.ensureCooldowns();
let { strategy } = $hh.test.tranches;

await acm.$receipt().grantRole($hh.test.deployer, await erc20Cooldown.COOLDOWN_WORKER_ROLE(), alice.address);
await $usde.mint(USDe, alice, 1000.0);

await $hh.test.snapshot('erc20Cooldown');


UAction.create({
    async $teardown() {
        await $hh.test.reset('erc20Cooldown');
    },
    async $after() {
        await $hh.test.reset();
    },
    async 'transfer via cooldown'() {

        await transfer(erc20Cooldown, USDe, alice, bob, 20n, '60s');
        await transfer(erc20Cooldown, USDe, alice, bob, 30n, '120s');

        await $hh.test.mine(`30s`);

        // no transfers yet
        await $erc20.eqBalance(USDe, bob, 0n);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 50n, nextUnlockAmount: 20n });

        // fail to withdraw
        console.log(await erc20Cooldown.balanceOf(USDe.address, bob.address));
        try {
            await $testCooldown.finalize(erc20Cooldown, USDe, bob);
            throw new Error(`Unreached`)
        } catch (error) {
            console.log(error);
            $require.notEq(error.message, 'Unreached');
        }

        // #1: 60s passed, withdraw 1. portion
        await $hh.test.mine(`51s`);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 30n, claimable: 20n, nextUnlockAmount: 30n });

        await $testCooldown.finalize(erc20Cooldown, USDe, bob);
        await $erc20.eqBalance(USDe, bob, 20n);

        // No balance yet
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 30n, claimable: 0n, nextUnlockAmount: 30n });

        // #2: 120s passed, withdraw 2. portion
        await $hh.test.mine(`61s`);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 0n, claimable: 30n, nextUnlockAmount: 0n });
        await $testCooldown.finalize(erc20Cooldown, USDe, bob);
        await $erc20.eqBalance(USDe, bob, 50n);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 0n, claimable: 0n, nextUnlockAmount: 0n });
    },

    async 'emergency disable'() {

        await transfer(erc20Cooldown, USDe, alice, bob.address, 21n, '7days');

        let result = await $promise.caught($testCooldown.finalize(erc20Cooldown, USDe, bob.address));
        $require.match(/NothingToFinalize/, result.error?.message);

        await erc20Cooldown.$receipt().setCooldownDisabled(alice, USDe.address, true);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, { pending: 0n, claimable: 21n, nextUnlockAmount: 0n, nextUnlockAt: 0n });
        await $testCooldown.finalize(erc20Cooldown, USDe, bob.address);
        await $erc20.eqBalance(USDe, bob, 21n);
    },
    async 'ensure unstake request is reused within single block'() {

        await USDe.$receipt().approve(alice, erc20Cooldown.address, 50n);
        await $hh.test.client.debug.setAutomine(false);
        await $promise.wait(200);
        let tx1 = await erc20Cooldown.transfer(alice, USDe.address, alice.address, bob.address, 23n, _7DAYS);
        let tx2 = await erc20Cooldown.transfer(alice, USDe.address, alice.address, bob.address, 27n, _7DAYS);
        await $promise.wait(200);
        await $hh.test.client.debug.setAutomine(true);
        await $hh.test.client.debug.mine(1);

        let [ r1, r2 ] = await Promise.all([tx1.wait(), tx2.wait()]);

        l`1 request only, as 2 requests were made in the same block`;
        $require.eq(r1.blockNumber, r2.blockNumber, 'different blocks');

        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, {
            pending: 50n,
            nextUnlockAmount: 50n,
            totalRequests: 1n
        });

        await $hh.test.mine(`7days`);
        await $testCooldown.finalize(erc20Cooldown, USDe, bob.address);
        await $erc20.eqBalance(USDe, bob, 50n);
    },
    async 'max active requests'() {
        await USDe.$receipt().approve(alice, erc20Cooldown.address, 80n);
        const MAX = $hh.isCoverage() ? 2 : 71;
        for (let i = 0; i < MAX; i++) {
            await erc20Cooldown.$receipt().transfer(alice, USDe.address, bob.address, bob.address, 1n, _7DAYS);
        }
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, {
            pending: BigInt(MAX),
            nextUnlockAmount: 1n,
            totalRequests: BigInt(Math.min(MAX, 70))
        });
        await $hh.test.mine(`8days`);
        await $testCooldown.finalize(erc20Cooldown, USDe, bob.address);
        await $erc20.eqBalance(USDe, bob, BigInt(MAX));
    },
    async 'max external requests'() {
        await USDe.$receipt().approve(alice, erc20Cooldown.address, 80n);
        const MAX =  $hh.isCoverage() ? 2 : 40;
        for (let i = 0; i < MAX; i++) {
            await erc20Cooldown.$receipt().transfer(alice, USDe.address, alice.address, bob.address, 1n, _7DAYS);
        }
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, {
            pending: 40n,
            nextUnlockAmount: 1n,
            totalRequests: 40n
        });

        let result = await $promise.caught(() => {
            return erc20Cooldown.$receipt().transfer(alice, USDe.address, alice.address, bob.address, 1n, _7DAYS);
        });
        $require.match(/ExternalReceiverRequestLimitReached/, result.error?.message);

        await erc20Cooldown.$receipt().transfer(alice, USDe.address, bob.address, bob.address, 5n, _7DAYS);
        await $testCooldown.eqBalanceOf(erc20Cooldown, USDe, bob, {
            pending: 45n,
            nextUnlockAmount: 1n,
            totalRequests: 41n
        });

        await $hh.test.mine(`8days`);
        await $testCooldown.finalize(erc20Cooldown, USDe, bob.address);
        await $erc20.eqBalance(USDe, bob, 45n);
    }
})


async function transfer(cooldown: ERC20Cooldown, token: ERC20 | any, from: TEth.IAccount, to: $acc.Address, amount: bigint, timespan: string) {
    let cooldownSeconds = BigInt(Math.floor($date.parseTimespan(timespan) / 1000));
    await token.$receipt().approve(from, cooldown.address, amount);
    await cooldown.$receipt().transfer(from, token.address, from.address, $acc.toAddress(to), amount, cooldownSeconds);
}
