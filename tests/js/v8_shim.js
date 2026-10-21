// node:v8 shim — exports, round-trips and documented divergences.
const v8 = require('node:v8');
const assert = require('node:assert');

console.log('exports', Object.keys(v8).join(','));
console.log('isNotProcess', v8 !== require('node:process'));

// --- heap statistics -------------------------------------------------
const hs = v8.getHeapStatistics();
console.log('heapKeys', Object.keys(hs).length);
console.log('heapShape', [
    'total_heap_size', 'total_heap_size_executable', 'total_physical_size',
    'total_available_size', 'used_heap_size', 'heap_size_limit',
    'malloced_memory', 'peak_malloced_memory', 'does_zap_garbage',
    'number_of_native_contexts', 'number_of_detached_contexts',
    'total_global_handles_size', 'used_global_handles_size', 'external_memory',
].every((k) => typeof hs[k] === 'number'));
console.log('heapInvariants', hs.used_heap_size > 0 && hs.used_heap_size <= hs.total_heap_size &&
    hs.heap_size_limit > 0 && hs.total_available_size >= 0);
console.log('zapType', typeof hs.does_zap_garbage);

const spaces = v8.getHeapSpaceStatistics();
console.log('spaceKeys', Object.keys(spaces[0]).join(','));
console.log('spaceName', spaces[0].space_name);

const code = v8.getHeapCodeStatistics();
console.log('codeKeys', Object.keys(code).join(','));
console.log('codeTypes', Object.keys(code).every((k) => typeof code[k] === 'number'));

console.log('tag', typeof v8.cachedDataVersionTag(), v8.cachedDataVersionTag() >>> 0 === v8.cachedDataVersionTag());

// --- startup snapshot -------------------------------------------------
console.log('building', !!v8.startupSnapshot.isBuildingSnapshot());
try {
    v8.startupSnapshot.addSerializeCallback(() => {});
    console.log('callbackThrows', false);
} catch (e) {
    console.log('callbackThrows', e.code === 'ERR_NOT_BUILDING_SNAPSHOT');
}

// --- serialization ----------------------------------------------------
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
        for (const [k, v] of a) if (!b.has(k)) return false;
        return true;
    }
    if (ta === '[object Set]') {
        if (a.size !== b.size) return false;
        for (const v of a) if (!b.has(v)) return false;
        return true;
    }
    if (ArrayBuffer.isView(a)) {
        if (a.byteLength !== b.byteLength) return false;
        const va = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
        const vb = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
        for (let i = 0; i < va.length; i++) if (va[i] !== vb[i]) return false;
        return true;
    }
    const ka = Object.keys(a), kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
        if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
        if (!deepEqual(a[k], b[k], seen)) return false;
    }
    return true;
}

const primitives = [-0, NaN, Infinity, -Infinity, 0, 1.5, 'x', true, null, undefined, 123n];
console.log('roundtripPrimitives', primitives.every((v) => deepEqual(v8.deserialize(v8.serialize(v)), v)));

const sparse = [1, , 3];
const sparseBack = v8.deserialize(v8.serialize(sparse));
console.log('roundtripSparse', sparseBack.length === 3 && !(1 in sparseBack) && sparseBack[0] === 1 && sparseBack[2] === 3);

const cycle = { name: 'root' };
cycle.self = cycle;
cycle.list = [cycle, { deep: new Map([[{ k: 1 }, new Set([1, 2])]]) }];
const cycleBack = v8.deserialize(v8.serialize(cycle));
console.log('roundtripCycle', cycleBack.self === cycleBack && cycleBack.list[0] === cycleBack);

const graph = {
    d: new Date('2020-01-02T03:04:05.000Z'),
    re: /a+b/gi,
    big: 9007199254740993n,
    map: new Map([['k', { v: 1 }]]),
    set: new Set([1, 'two']),
    buf: Buffer.from('hello'),
    u8: new Uint8Array([1, 2, 3]),
    dv: new DataView(new ArrayBuffer(8), 2, 4),
    err: Object.assign(new TypeError('boom'), { code: 'E_BOOM' }),
    nested: { a: [1, { b: null }] },
};
const graphBack = v8.deserialize(v8.serialize(graph));
console.log('roundtripGraph', deepEqual(graphBack, graph) &&
    Buffer.isBuffer(graphBack.buf) && graphBack.err instanceof Error &&
    graphBack.err.name === 'TypeError' && graphBack.err.code === 'E_BOOM');

// --- prototype safety --------------------------------------------------
const evil = JSON.parse('{"v":1,"root":{"t":"obj","id":0,"v":[["__proto__",{"t":"obj","id":1,"v":[["polluted",{"t":"bool","v":true}]]}]]}}');
const evilBack = v8.deserialize(Buffer.from(JSON.stringify(evil)));
console.log('protoSafe', Object.prototype.polluted === undefined &&
    Object.prototype.hasOwnProperty.call(evilBack, '__proto__') && evilBack.polluted === undefined);

// --- errors ------------------------------------------------------------
function throws(fn) {
    try { fn(); return false; } catch (e) { return true; }
}
console.log('throwsFunction', throws(() => v8.serialize(() => 1)));
console.log('throwsSymbol', throws(() => v8.serialize(Symbol('s'))));
console.log('throwsCorrupt', throws(() => v8.deserialize(Buffer.from('not json'))));
console.log('throwsBadArg', throws(() => v8.deserialize('abc')));
console.log('throwsSnapshot', throws(() => v8.getHeapSnapshot()));
console.log('flagsNoop', v8.setFlagsFromString('--no-opt') === undefined);
