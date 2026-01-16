
import { MockStakedUSDe } from '@0xc/hardhat/MockStakedUSDe/MockStakedUSDe';
import { TEth } from 'dequanto/models/TEth';
import { ERC20 } from 'dequanto/prebuilt/openzeppelin/ERC20';
import { $bigint } from 'dequanto/utils/$bigint';
import { l } from 'dequanto/utils/$logger';
import { $require } from 'dequanto/utils/$require';

export namespace $ethena {
    export async function distribute (sUSDe: MockStakedUSDe | any, USDe: ERC20 | any, distributor: TEth.IAccount,  amount: number | bigint) {

        await USDe.$receipt().approve(distributor, sUSDe.address, $bigint.MAX_UINT256);
        let amountWei = typeof amount === 'number'
            ? $bigint.toWei(amount, 18)
            : amount;

        let balance = await USDe.balanceOf(distributor.address);
        if (balance < amountWei) {
            await (USDe as any).$receipt().mint(distributor, distributor.address, amountWei);
        }
        l`Distributing yellow<${amount}>`;
        await sUSDe.$receipt().transferInRewards(distributor, amountWei);
    }

    export async function setCooldownDuration (sUSDe: MockStakedUSDe, sender: TEth.IAccount, seconds: number) {
        $require.eq(sUSDe.client.platform, 'hardhat');
        await sUSDe.$receipt().setCooldownDuration(sender, seconds);
    }
}
