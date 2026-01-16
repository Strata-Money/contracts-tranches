import { SharesCooldown } from '@0xc/hardhat/SharesCooldown/SharesCooldown';
import { TwoStepConfigManager } from '@0xc/hardhat/TwoStepConfigManager/TwoStepConfigManager';
import { TEth } from 'dequanto/models/TEth';
import { $bigint } from 'dequanto/utils/$bigint';
import { $require } from 'dequanto/utils/$require';

export namespace $exitMode {

    interface IExitMode {
        // Percentage
        covPct: number
        // Duration (seconds)
        lock?: number
        // Exit fee percentage
        feePct?: number
    }

    export async function propose (proposer: TEth.IAccount, twoStepConfig: TwoStepConfigManager, jrt: IExitMode[], srt: IExitMode[], delay?: number) {
        await twoStepConfig.$receipt().scheduleExitModeBoundsChange(proposer, map(jrt), map(srt), BigInt(delay ?? 24 * 60 * 60));
    }
    export function map (modes: IExitMode[]) {
        while (modes.length < 3) {
            modes.unshift({ covPct: 0 });
        }

        const arr = modes.map(mode => {
            return {
                coverage: Number($bigint.toWei(mode.covPct / 100, 6)),
                sharesLock: mode.lock ?? 0,
                fee: Number($bigint.toWei((mode.feePct ?? 0) / 100, 6)),
                assetsLock: 0
            };
        });
        return {
            p0: arr[0].coverage,
            p1: arr[1]?.coverage ?? 0,
            r0: { feePpm: arr[0].fee, sharesLock: arr[0].sharesLock },
            r1: { feePpm: arr[1]?.fee ?? 0, sharesLock: arr[1]?.sharesLock ?? 0 },
            r2: { feePpm: arr[2]?.fee ?? 0, sharesLock: arr[2]?.sharesLock ?? 0 },
        }
    }

    export async function set (sharesCooldown: SharesCooldown, twoStepConfig: TEth.IAccount, vault: TEth.Address, modes: IExitMode[]): Promise<void> {
        $require.eq(sharesCooldown.client.platform, 'hardhat')
        await sharesCooldown.client.debug.setBalance(twoStepConfig.address, BigInt(1e18));
        await sharesCooldown.$receipt().setVaultExitBounds({
            address: twoStepConfig.address,
            type: 'impersonated',
        }, vault, map(modes));
    }

    export async function execute (executor: TEth.IAccount, twoStepConfig: TwoStepConfigManager) {
        await twoStepConfig.$receipt().executeExitModeBoundsChange(executor);
    }
}
