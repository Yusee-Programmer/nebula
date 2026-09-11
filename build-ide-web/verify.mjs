import { readFileSync } from 'fs';
const bytes = readFileSync(new URL('./nebula.wasm', import.meta.url));
const mod = await WebAssembly.compile(bytes);
console.log('imports:', WebAssembly.Module.imports(mod).map(i => i.name).join(', '));
let drawCalls = 0;
const env = {
  js_set_canvas_size(w, h) { console.log('canvas size:', w, h); },
  js_fill_rect() { drawCalls++; },
  js_rounded_rect() { drawCalls++; },
  js_circle() { drawCalls++; },
  js_fill_text() { drawCalls++; },
};
const instance = await WebAssembly.instantiate(mod, { env });
const ex = instance.exports;
const hb = ex.__heap_base.value ?? ex.__heap_base;
console.log('calling heap_init...');
ex.nebula_heap_init(hb, BigInt(ex.memory.buffer.byteLength - hb));
console.log('heap_init returned');
console.log('calling nebula_init...');
ex.nebula_init(1000n, 680n);
console.log('nebula_init returned, frames=', ex.nebula_frames());
console.log('calling nebula_frame...');
ex.nebula_frame(1000n, 680n, 500n, 300n, 0n, 0n, 0n);
console.log('nebula_frame returned, frames=', ex.nebula_frames(), 'draw calls this frame:', drawCalls);
console.log('ALL OK -- Nebula Studio (ide_demo_web) runs end-to-end.');
