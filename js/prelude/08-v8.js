// ---- v8 ------------------------------------------------------------
// A shim over QuickJS, not a V8 backend. QuickJS has no V8 serializer and no
// heap-snapshot format, so `serialize` uses a documented local format and the
// snapshot APIs refuse rather than emit something unreadable. Everything else
// mirrors Node's shape with the approximations listed in docs/COMPAT.md.
(function (g) {
    'use strict';

    var MAX_SERIALIZED = 256 * 1024 * 1024;
    var DEFAULT_MEMORY_LIMIT = 256 * 1024 * 1024;
    var CACHED_DATA_VERSION_TAG = 0x9E3779B9 >>> 0;

    function cloneError(value) {
        var text;
        try { text = String(value); } catch (e) { text = typeof value; }
        // Node throws a plain Error here, with no code and no DOMException.
        return new Error(text + ' could not be cloned.');
    }

    function notBuildingSnapshot() {
        var e = new Error('Operation cannot be invoked when not building startup snapshot');
        e.code = 'ERR_NOT_BUILDING_SNAPSHOT';
        throw e;
    }

    function snapshotUnsupported(what) {
        var e = new Error(what + ' is not implemented by djs: QuickJS has no V8 heap-snapshot format');
        e.code = 'ERR_NOT_IMPLEMENTED';
        throw e;
    }

    function corrupt() {
        return new Error('Unable to deserialize cloned data due to invalid or unsupported version.');
    }

    function defineHidden(obj, key, value) {
        Object.defineProperty(obj, key, {
            value: value, enumerable: false, writable: true, configurable: true,
        });
    }

    function define(obj, key, value) {
        // defineProperty, not `obj[key] = value`: a "__proto__" key in
        // attacker-supplied bytes must stay an own property.
        Object.defineProperty(obj, key, {
            value: value, enumerable: true, writable: true, configurable: true,
        });
    }

    var TYPED_ARRAYS = {
        Int8Array: g.Int8Array,
        Uint8Array: g.Uint8Array,
        Uint8ClampedArray: g.Uint8ClampedArray,
        Int16Array: g.Int16Array,
        Uint16Array: g.Uint16Array,
        Int32Array: g.Int32Array,
        Uint32Array: g.Uint32Array,
        Float32Array: g.Float32Array,
        Float64Array: g.Float64Array,
    };
    if (g.BigInt64Array) {
        TYPED_ARRAYS.BigInt64Array = g.BigInt64Array;
        TYPED_ARRAYS.BigUint64Array = g.BigUint64Array;
    }

    function binaryCtorName(value) {
        if (g.Buffer.isBuffer(value)) return 'Buffer';
        if (value instanceof ArrayBuffer) return 'ArrayBuffer';
        if (value instanceof DataView) return 'DataView';
        if (ArrayBuffer.isView(value)) {
            for (var name in TYPED_ARRAYS)
                if (value instanceof TYPED_ARRAYS[name]) return name;
        }
        return null;
    }

    function serialize(value) {
        var ids = new Map();
        var nextId = 0;

        function enc(v) {
            var t = typeof v;
            if (v === undefined) return { t: 'undef' };
            if (v === null) return { t: 'null' };
            if (t === 'boolean') return { t: 'bool', v: v };
            if (t === 'number') {
                if (v !== v) return { t: 'num', v: 'NaN' };
                if (v === Infinity) return { t: 'num', v: 'Infinity' };
                if (v === -Infinity) return { t: 'num', v: '-Infinity' };
                if (v === 0 && 1 / v === -Infinity) return { t: 'num', v: '-0' };
                return { t: 'num', v: v };
            }
            if (t === 'string') return { t: 'str', v: v };
            if (t === 'bigint') return { t: 'bigint', v: String(v) };
            if (t === 'function' || t === 'symbol') throw cloneError(v);
            if (typeof SharedArrayBuffer !== 'undefined' && v instanceof SharedArrayBuffer)
                throw cloneError(v);
            if (v instanceof WeakMap || v instanceof WeakSet || v instanceof Promise)
                throw cloneError(v);

            var seen = ids.get(v);
            if (seen !== undefined) return { t: 'ref', i: seen };
            var id = nextId++;
            ids.set(v, id);

            if (Array.isArray(v)) {
                var items = new Array(v.length);
                for (var i = 0; i < v.length; i++)
                    items[i] = (i in v) ? enc(v[i]) : null; // null slot = hole
                return { t: 'arr', id: id, v: items };
            }
            if (v instanceof Date) {
                var ms = v.getTime();
                return { t: 'date', id: id, v: (ms !== ms) ? 'NaN' : ms };
            }
            if (v instanceof RegExp) return { t: 're', id: id, s: v.source, f: v.flags };

            var bin = binaryCtorName(v);
            if (bin !== null) {
                var backing = v instanceof ArrayBuffer ? v : v.buffer;
                var off = v instanceof ArrayBuffer ? 0 : v.byteOffset;
                var len = v instanceof ArrayBuffer ? v.byteLength : v.byteLength;
                return {
                    t: 'bin',
                    id: id,
                    ctor: bin,
                    off: off,
                    len: len,
                    back: backing.byteLength,
                    v: g.Buffer.from(new Uint8Array(backing)).toString('base64'),
                };
            }

            if (v instanceof Map) {
                var pairs = [];
                v.forEach(function (val, key) { pairs.push([enc(key), enc(val)]); });
                return { t: 'map', id: id, v: pairs };
            }
            if (v instanceof Set) {
                var members = [];
                v.forEach(function (val) { members.push(enc(val)); });
                return { t: 'set', id: id, v: members };
            }
            if (v instanceof Error) {
                var props = [];
                var own = Object.keys(v);
                for (var j = 0; j < own.length; j++) {
                    if (own[j] === 'name' || own[j] === 'message' || own[j] === 'stack') continue;
                    props.push([own[j], enc(v[own[j]])]);
                }
                return {
                    t: 'err',
                    id: id,
                    n: String(v.name),
                    m: String(v.message),
                    s: typeof v.stack === 'string' ? v.stack : '',
                    p: props,
                };
            }

            var out = [];
            var keys = Object.keys(v);
            for (var k = 0; k < keys.length; k++)
                out.push([keys[k], enc(v[keys[k]])]);
            return { t: 'obj', id: id, v: out };
        }

        var text = JSON.stringify({ v: 1, root: enc(value) });
        if (text.length > MAX_SERIALIZED) {
            var big = new Error('Cannot serialize value: serialized data exceeds ' + MAX_SERIALIZED + ' bytes');
            big.code = 'ERR_BUFFER_TOO_LARGE';
            throw big;
        }
        return g.Buffer.from(text, 'utf8');
    }

    function deserialize(buffer) {
        if (!(buffer instanceof Uint8Array) && !(buffer instanceof DataView)) {
            var typeErr = new TypeError('The "buffer" argument must be an instance of TypedArray or DataView');
            typeErr.code = 'ERR_INVALID_ARG_TYPE';
            throw typeErr;
        }
        var bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
        var text = g.Buffer.from(bytes).toString('utf8');
        var doc;
        try { doc = JSON.parse(text); } catch (e) { throw corrupt(); }
        if (doc === null || typeof doc !== 'object' || doc.v !== 1 || !('root' in doc))
            throw corrupt();

        var table = [];

        function dec(n) {
            if (n === null || typeof n !== 'object' || typeof n.t !== 'string')
                throw corrupt();
            switch (n.t) {
            case 'undef':
                return undefined;
            case 'null':
                return null;
            case 'bool':
                if (typeof n.v !== 'boolean') throw corrupt();
                return n.v;
            case 'num':
                if (n.v === 'NaN') return NaN;
                if (n.v === 'Infinity') return Infinity;
                if (n.v === '-Infinity') return -Infinity;
                if (n.v === '-0') return -0;
                if (typeof n.v !== 'number') throw corrupt();
                return n.v;
            case 'str':
                if (typeof n.v !== 'string') throw corrupt();
                return n.v;
            case 'bigint':
                if (typeof n.v !== 'string') throw corrupt();
                try { return g.BigInt(n.v); } catch (e) { throw corrupt(); }
            case 'ref':
                if (typeof n.i !== 'number' || n.i < 0 || n.i >= table.length)
                    throw corrupt();
                return table[n.i];
            case 'arr': {
                if (n.id !== table.length || !Array.isArray(n.v)) throw corrupt();
                var arr = [];
                table.push(arr);
                for (var i = 0; i < n.v.length; i++) {
                    if (n.v[i] === null) arr.length = i + 1; // hole
                    else arr[i] = dec(n.v[i]);
                }
                arr.length = n.v.length;
                return arr;
            }
            case 'obj': {
                if (n.id !== table.length || !Array.isArray(n.v)) throw corrupt();
                var obj = {};
                table.push(obj);
                for (var k = 0; k < n.v.length; k++) {
                    var pair = n.v[k];
                    if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== 'string')
                        throw corrupt();
                    define(obj, pair[0], dec(pair[1]));
                }
                return obj;
            }
            case 'map': {
                if (n.id !== table.length || !Array.isArray(n.v)) throw corrupt();
                var map = new Map();
                table.push(map);
                for (var m = 0; m < n.v.length; m++) {
                    var entry = n.v[m];
                    if (!Array.isArray(entry) || entry.length !== 2) throw corrupt();
                    map.set(dec(entry[0]), dec(entry[1]));
                }
                return map;
            }
            case 'set': {
                if (n.id !== table.length || !Array.isArray(n.v)) throw corrupt();
                var set = new Set();
                table.push(set);
                for (var s = 0; s < n.v.length; s++) set.add(dec(n.v[s]));
                return set;
            }
            case 'date': {
                if (n.id !== table.length) throw corrupt();
                if (n.v !== 'NaN' && typeof n.v !== 'number') throw corrupt();
                var date = new Date(n.v === 'NaN' ? NaN : n.v);
                table.push(date);
                return date;
            }
            case 're': {
                if (n.id !== table.length) throw corrupt();
                if (typeof n.s !== 'string' || typeof n.f !== 'string') throw corrupt();
                var re;
                try { re = new RegExp(n.s, n.f); } catch (e) { throw corrupt(); }
                table.push(re);
                return re;
            }
            case 'err': {
                if (n.id !== table.length) throw corrupt();
                var err = new Error(typeof n.m === 'string' ? n.m : '');
                // name/stack stay non-enumerable, as on a real Error; assigning
                // them would create enumerable own properties and change the
                // object's key set on round-trip.
                if (typeof n.n === 'string') defineHidden(err, 'name', n.n);
                if (typeof n.s === 'string') defineHidden(err, 'stack', n.s);
                table.push(err);
                if (Array.isArray(n.p)) {
                    for (var p = 0; p < n.p.length; p++) {
                        var prop = n.p[p];
                        if (!Array.isArray(prop) || prop.length !== 2 || typeof prop[0] !== 'string')
                            throw corrupt();
                        define(err, prop[0], dec(prop[1]));
                    }
                }
                return err;
            }
            case 'bin': {
                if (n.id !== table.length) throw corrupt();
                if (typeof n.v !== 'string' || typeof n.back !== 'number' ||
                    typeof n.off !== 'number' || typeof n.len !== 'number' ||
                    typeof n.ctor !== 'string')
                    throw corrupt();
                if (n.off < 0 || n.len < 0 || n.back < 0 || n.off + n.len > n.back)
                    throw corrupt();
                var raw = g.Buffer.from(n.v, 'base64');
                if (raw.length < n.back) throw corrupt();
                var backing = new ArrayBuffer(n.back);
                new Uint8Array(backing).set(raw.subarray(0, n.back));
                var built;
                if (n.ctor === 'ArrayBuffer') built = backing;
                else if (n.ctor === 'Buffer') built = new g.Buffer(backing, n.off, n.len);
                else if (n.ctor === 'DataView') built = new DataView(backing, n.off, n.len);
                else {
                    var Ctor = TYPED_ARRAYS[n.ctor];
                    if (!Ctor) throw corrupt();
                    built = new Ctor(backing, n.off, n.len);
                }
                table.push(built);
                return built;
            }
            default:
                throw corrupt();
            }
        }

        return dec(doc.root);
    }

    function heapStats() {
        var s = g.__djs.process.memoryStats();
        var limit = s.memoryLimit > 0 ? s.memoryLimit : DEFAULT_MEMORY_LIMIT;
        return {
            s: s,
            limit: limit,
        };
    }

    function getHeapStatistics() {
        var h = heapStats();
        // Node 22.11 key order and names. Values are QuickJS's accounting:
        // shape-compatible, not numerically comparable with V8.
        return {
            total_heap_size: h.s.mallocSize,
            total_heap_size_executable: h.s.jsFuncCodeSize,
            total_physical_size: h.s.mallocSize,
            total_available_size: Math.max(h.limit - h.s.mallocSize, 0),
            used_heap_size: h.s.memoryUsedSize,
            heap_size_limit: h.limit,
            malloced_memory: 0,
            peak_malloced_memory: 0,
            does_zap_garbage: 0,
            number_of_native_contexts: 1,
            number_of_detached_contexts: 0,
            total_global_handles_size: 0,
            used_global_handles_size: 0,
            external_memory: h.s.arrayBufferBytes,
        };
    }

    function getHeapSpaceStatistics() {
        var h = heapStats();
        return [{
            space_name: 'quickjs',
            space_size: h.s.mallocSize,
            space_used_size: h.s.memoryUsedSize,
            space_available_size: Math.max(h.limit - h.s.mallocSize, 0),
            physical_space_size: h.s.mallocSize,
        }];
    }

    function getHeapCodeStatistics() {
        var s = g.__djs.process.memoryStats();
        return {
            code_and_metadata_size: s.jsFuncCodeSize,
            bytecode_and_metadata_size: 0,
            external_script_source_size: 0,
            cpu_profiler_metadata_size: 0,
        };
    }

    function cachedDataVersionTag() {
        return CACHED_DATA_VERSION_TAG;
    }

    function setFlagsFromString() {
        // QuickJS has no V8 flag system; accepted and ignored.
    }

    var startupSnapshot = {
        isBuildingSnapshot: function () { return false; },
        addSerializeCallback: notBuildingSnapshot,
        addDeserializeCallback: notBuildingSnapshot,
        setDeserializeMainFunction: notBuildingSnapshot,
    };

    g.v8 = {
        cachedDataVersionTag: cachedDataVersionTag,
        deserialize: deserialize,
        getHeapCodeStatistics: getHeapCodeStatistics,
        getHeapSpaceStatistics: getHeapSpaceStatistics,
        getHeapSnapshot: function () { snapshotUnsupported('getHeapSnapshot'); },
        getHeapStatistics: getHeapStatistics,
        serialize: serialize,
        setFlagsFromString: setFlagsFromString,
        startupSnapshot: startupSnapshot,
        writeHeapSnapshot: function () { snapshotUnsupported('writeHeapSnapshot'); },
    };
})(globalThis);
