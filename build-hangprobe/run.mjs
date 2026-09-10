// Calls each probe export in its OWN worker with a hard timeout, so one
// hanging export does not hide the results of the others.
import { readFileSync } from 'fs';
import { Worker, isMainThread, workerData, parentPort } from 'worker_threads';

const WASM = new URL('./nebula.wasm', import.meta.url);

if (!isMainThread) {
  const bytes = readFileSync(WASM);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const ex = instance.exports;
  const hb = ex.__heap_base.value ?? ex.__heap_base;
  ex.nebula_heap_init(hb, BigInt(ex.memory.buffer.byteLength - hb));
  const r = ex[workerData.fn]();
  parentPort.postMessage(String(r));
} else {
  const names = ['t1_concat', 't2_replace', 't3_replace_empty',
                 't4_replace_missing', 't5_dict_items', 't6_substitute'];
  for (const fn of names) {
    const res = await new Promise(resolve => {
      const w = new Worker(new URL(import.meta.url), { workerData: { fn } });
      const timer = setTimeout(() => { w.terminate(); resolve('*** HANG (2s timeout) ***'); }, 2000);
      w.on('message', m => { clearTimeout(timer); w.terminate(); resolve('ok -> ' + m); });
      w.on('error', e => { clearTimeout(timer); resolve('ERROR: ' + e.message); });
    });
    console.log(fn.padEnd(20), res);
  }
}
