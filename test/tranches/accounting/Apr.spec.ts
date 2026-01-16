import { UTest } from 'atma-utest'
import { $hh } from '../utils/$hh';
import { AccountingExecutor } from './AccountingExecutor';
import { $apr } from '@s/utils/$apr';
import { ProtocolExecutor } from '../utils/ProtocolExecutor';

await $hh.test.deploy();

UTest.create({
    async $teardown () {
        await $hh.test.reset();
    },
    async $after () {
        await $hh.test.reset();
    },
    async 'changes APR in the middle' () {
        let exec = new AccountingExecutor($hh.test);
        let srt$ = $apr.value(1000);
        let jrt$ = $apr.value(1000);
        let nav$ = $apr.value(2000);

        await exec.run({
            steps: [
                { balanceFlow: [jrt$.$, 0, srt$.$, 0] },
                // APRssr == APRbase
                { aprs: [ 0.1, 0.1 ] },
                { time: '11months' },
                { totalAssets: nav$.next(.1, 11) }, // apr 10%

                { eqAvg: [ null, srt$.next(.1, 11) ]}, // ssr 10%

                { aprs: [ 0.8, 0.8 ] },
                { time: '1month' },
                { totalAssets: nav$.next(.8, 1)},
                { eqAvg: [
                    null,
                    srt$.next(.8, 1)
                ]}
            ]
        });
    },
    async 'changes APRssr only' () {
        let exec = new AccountingExecutor($hh.test);
        let srt$ = $apr.value(1000);
        let jrt$ = $apr.value(1000);
        let nav$ = $apr.value(2000);

        await exec.run({
            steps: [
                { balanceFlow: [jrt$.$, 0, srt$.$, 0] },
                { aprs: [ 0.1, 0 ] },
                { time: '11months' },
                { totalAssets: nav$.$ },

                { eqAvg: [ null, srt$.next(.1, 11) ]},

                { aprs: [ 0.8, 0 ] },
                { time: '1month' },
                { totalAssets: nav$.$ },
                { eqAvg: [
                    null,
                    srt$.next(.8, 1)
                ]}
            ]
        });
    },
    async 'drastically change the APR due to TVL ratio' () {
        let exec = new ProtocolExecutor($hh.test);

        await exec.run({
            steps: [
                { aprsFixed: { target: 0, base: 0.5 } },
                { risk: [0, .9, 1] },
                { user: 'alice' },
                { deposit: { jrt: 1000 } },
                { eqAprSrt: .5 * (1 - (0 + .9 * (0) ** 1)) },

                { time: '1min' },
                { user: 'bob' },
                { deposit: { srt: 1000  } },

                { user: 'alice'},

                { deposit: { srt: 3000  } },
                { eqAprSrt: .5 * (1 - (0 + .9 * (0.8) ** 1)) }, // 4K Srt and 1K Jrt (TVLsrt 0.8)
                { time: '1month' },
                { logNav: true },
                //{ eqUserAssets: { srt: $apr.final(3000, .5 * (1 - (0 + .9 * (0.8) ** 1)), '1month') } }


            ]
        });
    },
    async '//negative APRssr' () {
        let exec = new AccountingExecutor($hh.test);
        let srt$ = $apr.value(1000);
        let jrt$ = $apr.value(1000);
        let nav$ = $apr.value(2000);

        await exec.run({
            steps: [
                { balanceFlow: [jrt$.$, 0, srt$.$, 0] },
                { aprs: [ -0.1, 0 ] },
                { time: '12months' },
                { totalAssets: nav$.$ },
                { eqAvg: [
                    jrt$.next( 0.1, 12),
                    srt$.next(-0.1, 12)
                ]}
            ]
        });
    },
});
