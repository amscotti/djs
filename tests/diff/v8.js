// Differential case: Node's v8 and djs's shim must agree on the observable
// contract. Only fixed, normalized lines are printed — never key counts or
// space names, which legitimately differ (Node has more names than djs, and
// djs reports a single QuickJS space).
const v8 = require('node:v8');

function deepEqual(a, b, seen) {
    if (a === b) return a !== 0 || 1 / a === 1 / b;
    if (typeof a === 'number' && typeof b === 'number') return a !== a && b !== b;
    if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
    seen = seen || new Map();
    if (seen.get(a) === b) return true;
    seen.set(a, b);
    const ta = Object.prototype.toString.call(a);
    if (ta !== Object.prototype.toString.call(b)) return false;
    if (ta === '[object Date]') return a.getTime() === b.getTime() || (a.getTime() !== a.getTime() && b.getTime() !== b.getTime());
    if (ta === '[object RegExp]') return a.source === b.source && a.flags === b.flags;
    if (ta === '[object Map]') {
        if (a.size !== b.size) return false;
        for (const entry of a) if (!b.has(entry[0])) return false;
        return true;
    }
    if (ta === '[object Set]') {
        if (a.size !== b.size) return false;
        for (const value of a) if (!b.has(value)) return false;
        return true;
    }
    if (ArrayBuffer.isView(a)) {
        if (a.byteLength !== b.byteLength) return false;
        const va = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
        const vb = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
        for (let i = 0; i < va.length; i++) if (va[i] !== vb[i]) return false;
        return true;
    }
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
        if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
        if (!deepEqual(a[k], b[k], seen)) return false;
    }
    return true;
}

function throws(fn) {
    try { fn(); return false; } catch (e) { return true; }
}

console.log('serialize', typeof v8.serialize);
console.log('deserialize', typeof v8.deserialize);
console.log('getHeapStatistics', typeof v8.getHeapStatistics);
console.log('getHeapSpaceStatistics', typeof v8.getHeapSpaceStatistics);
console.log('getHeapCodeStatistics', typeof v8.getHeapCodeStatistics);
console.log('cachedDataVersionTag', typeof v8.cachedDataVersionTag);
console.log('setFlagsFromString', typeof v8.setFlagsFromString);
console.log('startupSnapshot', typeof v8.startupSnapshot);
console.log('building', !!v8.startupSnapshot.isBuildingSnapshot());

const hs = v8.getHeapStatistics();
const HEAP_KEYS = [
    'total_heap_size', 'total_heap_size_executable', 'total_physical_size',
    'total_available_size', 'used_heap_size', 'heap_size_limit',
    'malloced_memory', 'peak_malloced_memory', 'does_zap_garbage',
    'number_of_native_contexts', 'number_of_detached_contexts',
    'total_global_handles_size', 'used_global_handles_size', 'external_memory',
];
console.log('heapKeys', HEAP_KEYS.every((k) => typeof hs[k] === 'number'));
console.log('heapInvariants', hs.used_heap_size > 0 && hs.used_heap_size <= hs.total_heap_size);
console.log('heapLimit', hs.heap_size_limit > 0 && hs.total_available_size >= 0);

const spaces = v8.getHeapSpaceStatistics();
console.log('spaceKeys', Object.keys(spaces[0]).join(',') ===
    'space_name,space_size,space_used_size,space_available_size,physical_space_size');

const code = v8.getHeapCodeStatistics();
console.log('codeKeys', ['code_and_metadata_size', 'bytecode_and_metadata_size', 'external_script_source_size']
    .every((k) => typeof code[k] === 'number'));

const tag = v8.cachedDataVersionTag();
console.log('tag', typeof tag === 'number' && tag >= 0 && tag <= 0xFFFFFFFF && tag === Math.floor(tag));

const primitives = [-0, NaN, Infinity, -Infinity, 0, 1.5, 'x', true, null, undefined, 123n];
console.log('roundtripPrimitives',
    primitives.every((v) => deepEqual(v8.deserialize(v8.serialize(v)), v)));

const sparse = v8.deserialize(v8.serialize([1, , 3]));
console.log('roundtripSparse', sparse.length === 3 && !(1 in sparse) && sparse[0] === 1 && sparse[2] === 3);

const graph = {
    d: new Date('2020-01-02T03:04:05.000Z'),
    re: /a+b/gi,
    big: 9007199254740993n,
    map: new Map([['k', { v: 1 }]]),
    set: new Set([1, 'two']),
    buf: Buffer.from('hello'),
    u8: new Uint8Array([1, 2, 3]),
    dv: new DataView(new ArrayBuffer(8), 2, 4),
    nested: { a: [1, { b: null }] },
};
const graphBack = v8.deserialize(v8.serialize(graph));
console.log('roundtripGraph', deepEqual(graphBack, graph) && Buffer.isBuffer(graphBack.buf));

const cycle = { name: 'root' };
cycle.self = cycle;
const cycleBack = v8.deserialize(v8.serialize(cycle));
console.log('roundtripCycle', cycleBack.self === cycleBack);

console.log('throwsFunction', throws(() => v8.serialize(() => 1)));
console.log('throwsCorrupt', throws(() => v8.deserialize(Buffer.from('not json'))));
