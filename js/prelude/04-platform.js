    // ---- util ----------------------------------------------------------

    function promisify(fn) {
        if (typeof fn !== 'function') throw new TypeError('The "original" argument must be of type function');
        return function () {
            var self = this;
            var args = Array.prototype.slice.call(arguments);
            return new Promise(function (resolve, reject) {
                args.push(function (err, value) { if (err) reject(err); else resolve(value); });
                fn.apply(self, args);
            });
        };
    }
    function callbackify(fn) {
        return function () {
            var args = Array.prototype.slice.call(arguments);
            var cb = args.pop();
            fn.apply(this, args).then(function (v) { cb(null, v); }, cb);
        };
    }
    function inherits(ctor, superCtor) {
        ctor.super_ = superCtor;
        ctor.prototype = Object.create(superCtor.prototype, {
            constructor: { value: ctor, enumerable: false, writable: true, configurable: true }
        });
    }
    var utilModule = {
        // Resolves when the signal aborts; rejects with AbortError if the
        // resource closes first. Mirrors Node's util.aborted(signal, resource).
        aborted: function (signal, resource) {
            return new Promise(function (resolve, reject) {
                if (signal === null || typeof signal !== 'object' ||
                    typeof signal.addEventListener !== 'function')
                    throw new TypeError('The "signal" argument must be an instance of AbortSignal');
                if (signal.aborted) { resolve(); return; }
                var settled = false;
                function finish(fn, arg) {
                    if (settled) return;
                    settled = true;
                    signal.removeEventListener('abort', onAbort);
                    if (resource && typeof resource.removeListener === 'function')
                        resource.removeListener('close', onClose);
                    fn(arg);
                }
                function onAbort() { finish(resolve); }
                function onClose() {
                    var e = new Error('The operation was aborted');
                    e.name = 'AbortError';
                    e.code = 'ABORT_ERR';
                    finish(reject, e);
                }
                signal.addEventListener('abort', onAbort);
                if (resource && typeof resource.once === 'function')
                    resource.once('close', onClose);
            });
        },
        format: function () {
            var fmt = arguments[0];
            var rest = Array.prototype.slice.call(arguments, 1);
            return format(fmt, rest);
        },
        formatWithOptions: function (opts, fmt) {
            return format(fmt, Array.prototype.slice.call(arguments, 2));
        },
        inspect: function (value, opts) {
            return inspect(value, 0, [], true);
        },
        parseArgs: function (config) {
            config = config || {};
            var args = config.args || (g.process ? g.process.argv.slice(2) : []);
            var defs = config.options || {};
            var strict = config.strict !== false;
            var allowPositionals = !!config.allowPositionals;
            var values = {}, positionals = [];
            for (var name in defs) if (defs[name].default !== undefined) values[name] = defs[name].default;
            var shortMap = {};
            for (var n2 in defs) if (defs[n2].short) shortMap[defs[n2].short] = n2;
            function setVal(name, val) {
                var d = defs[name];
                if (!d) {
                    if (strict) { var e = new Error('Unknown option ' + name); e.code = 'ERR_PARSE_ARGS_UNKNOWN_OPTION'; throw e; }
                    values[name] = val; return;
                }
                if (d.multiple) { if (!Array.isArray(values[name])) values[name] = []; values[name].push(val); }
                else values[name] = val;
            }
            for (var i = 0; i < args.length; i++) {
                var a = args[i];
                if (a === '--') { for (var r = i + 1; r < args.length; r++) positionals.push(args[r]); break; }
                if (a.slice(0, 2) === '--') {
                    var body = a.slice(2), eq = body.indexOf('='), opt = eq >= 0 ? body.slice(0, eq) : body;
                    var d2 = defs[opt];
                    if (!d2 && strict) { var e2 = new Error('Unknown option --' + opt); e2.code = 'ERR_PARSE_ARGS_UNKNOWN_OPTION'; throw e2; }
                    if (d2 && d2.type === 'boolean') setVal(opt, eq >= 0 ? body.slice(eq + 1) === 'true' : true);
                    else if (eq >= 0) setVal(opt, body.slice(eq + 1));
                    else if (i + 1 < args.length) setVal(opt, args[++i]);
                    else setVal(opt, '');
                } else if (a.slice(0, 1) === '-' && a.length > 1) {
                    var short = a.slice(1, 2), opt2 = shortMap[short] || short;
                    var d3 = defs[opt2];
                    if (d3 && d3.type === 'boolean') setVal(opt2, true);
                    else if (a.length > 2) setVal(opt2, a.slice(2));
                    else if (i + 1 < args.length) setVal(opt2, args[++i]);
                    else setVal(opt2, '');
                } else {
                    if (!allowPositionals && strict) { var e3 = new Error('Unexpected positional argument ' + a); e3.code = 'ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL'; throw e3; }
                    positionals.push(a);
                }
            }
            return { values: values, positionals: positionals };
        },
        styleText: function (format, text) {
            var codes = { bold: [1, 22], dim: [2, 22], italic: [3, 23], underline: [4, 24], red: [31, 39], green: [32, 39], yellow: [33, 39], blue: [34, 39], magenta: [35, 39], cyan: [36, 39], white: [37, 39], gray: [90, 39] };
            var list = Array.isArray(format) ? format : [format];
            var open = '', close = '';
            for (var i = 0; i < list.length; i++) if (codes[list[i]]) { open += '\x1b[' + codes[list[i]][0] + 'm'; close = '\x1b[' + codes[list[i]][1] + 'm' + close; }
            return open + String(text) + close;
        },
        promisify: promisify,
        callbackify: callbackify,
        inherits: inherits,
        deprecate: function (fn) { return fn; },
        types: {
            isDate: function (v) { return v instanceof Date; },
            isRegExp: function (v) { return v instanceof RegExp; },
            isPromise: function (v) { return v && typeof v.then === 'function'; },
            isArrayBuffer: function (v) { return v instanceof ArrayBuffer; },
            isKeyObject: function (v) { return v instanceof KeyObject; },
            isUint8Array: function (v) { return v instanceof Uint8Array; },
            isProxy: function (v) { return __djs.process.isProxy(v); },
            isMap: function (v) { return v instanceof Map; },
            isSet: function (v) { return v instanceof Set; },
            isNativeError: function (v) { return v instanceof Error; },
            isBoxedPrimitive: function (v) {
                return v instanceof Number || v instanceof String || v instanceof Boolean ||
                    (typeof v === 'bigint' && false) || typeof v === 'symbol';
            }
        }
    };

    // ---- util: the remaining Node helpers -----------------------------
    utilModule.inspect.custom = inspectCustom;
    utilModule.inspect.defaultOptions = { depth: 2, colors: false, showHidden: false };
    utilModule.isDeepStrictEqual = function isDeepStrictEqual(a, b) {
        var seen = [];
        function eq(x, y) {
            if (Object.is(x, y)) return true;
            if (typeof x !== typeof y) return false;
            if (x === null || y === null) return false;
            if (typeof x !== 'object') return false;
            if (x instanceof Date || y instanceof Date)
                return x instanceof Date && y instanceof Date && x.getTime() === y.getTime();
            if (x instanceof RegExp || y instanceof RegExp)
                return x instanceof RegExp && y instanceof RegExp && String(x) === String(y);
            if (Buffer.isBuffer(x) || Buffer.isBuffer(y))
                return Buffer.isBuffer(x) && Buffer.isBuffer(y) && x.equals(y);
            for (var i = 0; i < seen.length; i++) if (seen[i][0] === x) return seen[i][1] === y;
            seen.push([x, y]);
            if (Array.isArray(x) !== Array.isArray(y)) return false;
            if (Array.isArray(x)) {
                if (x.length !== y.length) return false;
                for (var j = 0; j < x.length; j++) if (!eq(x[j], y[j])) return false;
                return true;
            }
            if (x instanceof Map || y instanceof Map) {
                if (!(x instanceof Map && y instanceof Map) || x.size !== y.size) return false;
                var okMap = true;
                x.forEach(function (v, k) { if (!eq(v, y.get(k))) okMap = false; });
                return okMap;
            }
            if (x instanceof Set || y instanceof Set) {
                if (!(x instanceof Set && y instanceof Set) || x.size !== y.size) return false;
                var arr = []; y.forEach(function (v) { arr.push(v); });
                var okSet = true;
                x.forEach(function (v) { if (arr.indexOf(v) < 0) okSet = false; });
                return okSet;
            }
            var kx = Object.keys(x), ky = Object.keys(y);
            if (kx.length !== ky.length) return false;
            for (var m = 0; m < kx.length; m++) {
                if (!Object.prototype.hasOwnProperty.call(y, kx[m])) return false;
                if (!eq(x[kx[m]], y[kx[m]])) return false;
            }
            return true;
        }
        return eq(a, b);
    };
    var errnoNames = {
        1: 'EPERM', 2: 'ENOENT', 3: 'ESRCH', 4: 'EINTR', 5: 'EIO', 6: 'ENXIO', 7: 'E2BIG',
        8: 'ENOEXEC', 9: 'EBADF', 11: 'EAGAIN', 12: 'ENOMEM', 13: 'EACCES', 14: 'EFAULT',
        16: 'EBUSY', 17: 'EEXIST', 18: 'EXDEV', 19: 'ENODEV', 20: 'ENOTDIR', 21: 'EISDIR',
        22: 'EINVAL', 23: 'ENFILE', 24: 'EMFILE', 25: 'ENOTTY', 27: 'EFBIG', 28: 'ENOSPC',
        29: 'ESPIPE', 30: 'EROFS', 31: 'EMLINK', 32: 'EPIPE', 33: 'EDOM', 34: 'ERANGE',
        36: 'ENAMETOOLONG', 38: 'ENOSYS', 39: 'ENOTEMPTY', 40: 'ELOOP', 95: 'EOPNOTSUPP',
        97: 'EAFNOSUPPORT', 98: 'EADDRINUSE', 99: 'EADDRNOTAVAIL', 103: 'ECONNABORTED',
        104: 'ECONNRESET', 105: 'ENOBUFS', 106: 'EISCONN', 107: 'ENOTCONN', 110: 'ETIMEDOUT',
        111: 'ECONNREFUSED', 112: 'EHOSTUNREACH', 113: 'EALREADY', 115: 'EINPROGRESS'
    };
    utilModule.getSystemErrorName = function (err) {
        // Node takes libuv's negative errno values and rejects everything else.
        var n = Number(err);
        if (!isFinite(n) || Math.floor(n) !== n) {
            var e = new TypeError('The "err" argument must be of type number');
            e.code = 'ERR_INVALID_ARG_TYPE';
            throw e;
        }
        if (n >= 0) {
            var r = new RangeError('The value of "err" is out of range. It must be a negative integer. Received ' + n);
            r.code = 'ERR_OUT_OF_RANGE';
            throw r;
        }
        var name = errnoNames[-n];
        if (name) return name;
        var unk = new Error('Unknown system error ' + n);
        unk.code = 'ERR_UNKNOWN_ERRNO';
        unk.errno = n;
        unk.syscall = '';
        throw unk;
    };
    utilModule.stripVTControlCharacters = function (str) {
        return String(str).replace(/\u001b\[[0-9;?]*[ -\/]*[@-~]/g, '');
    };
    utilModule.debuglog = function (section, callback) {
        var dbg = String(g.process && g.process.env && g.process.env.NODE_DEBUG ? g.process.env.NODE_DEBUG : '');
        var enabled = false;
        var parts = dbg.split(/[,\s]+/);
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i];
            if (!p) continue;
            if (p === '*') { enabled = true; break; }
            if (p.charAt(p.length - 1) === '*' ? String(section).toLowerCase().indexOf(p.slice(0, -1).toLowerCase()) === 0
                                               : p.toLowerCase() === String(section).toLowerCase()) { enabled = true; break; }
        }
        var label = String(section).toUpperCase();
        var fn = function () {
            var msg = utilModule.format.apply(utilModule, arguments);
            try { g.process.stderr.write(label + ' ' + String(Date.now()) + ': ' + msg + '\n'); } catch (e) { }
            if (typeof callback === 'function') callback(msg);
        };
        fn.enabled = enabled;
        return enabled ? fn : function () { };
    };

    // ---- timers/promises ----------------------------------------------

    var timersPromises = {
        setTimeout: function (ms, value) {
            return new Promise(function (resolve) { setTimeout(function () { resolve(value); }, ms); });
        },
        setImmediate: function (value) {
            return new Promise(function (resolve) { setImmediate(function () { resolve(value); }); });
        },
        // Node 22 scheduler: wait(ms, value) and yield() (a macrotask turn).
        scheduler: {
            wait: function (ms, value) {
                return new Promise(function (resolve) {
                    setTimeout(function () { resolve(value); }, ms);
                });
            },
            yield: function () {
                return new Promise(function (resolve) { setImmediate(resolve); });
            }
        }
    };

    g.timers = {
        setTimeout: setTimeout,
        clearTimeout: clearTimeout,
        setInterval: setInterval,
        clearInterval: clearTimeout,
        setImmediate: setImmediate,
        clearImmediate: clearImmediate
    };

    // ---- abort ---------------------------------------------------------

    function AbortSignal() {
        EventEmitter.call(this);
        this.aborted = false;
        this.reason = undefined;
        this.onabort = null;
    }
    AbortSignal.prototype = Object.create(EventEmitter.prototype);
    AbortSignal.prototype.constructor = AbortSignal;
    AbortSignal.prototype.addEventListener = function (name, fn) { this.on(name, fn); };
    AbortSignal.prototype.removeEventListener = function (name, fn) { this.off(name, fn); };
    AbortSignal.prototype.throwIfAborted = function () {
        if (this.aborted) throw this.reason || new Error('The operation was aborted');
    };
    AbortSignal.abort = function (reason) {
        var c = new AbortController();
        c.abort(reason);
        return c.signal;
    };
    AbortSignal.any = function (signals) {
        var c = new AbortController();
        var list = Array.prototype.slice.call(signals || []);
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].aborted) { c.abort(list[i].reason); return c.signal; }
        }
        for (var j = 0; j < list.length; j++) {
            (function (sig) {
                if (!sig || typeof sig.on !== 'function') return;
                sig.on('abort', function () { c.abort(sig.reason); });
            })(list[j]);
        }
        return c.signal;
    };
    AbortSignal.timeout = function (ms) {
        var c = new AbortController();
        setTimeout(function () { c.abort(new Error('The operation timed out')); }, ms);
        return c.signal;
    };

    function AbortController() { this.signal = new AbortSignal(); }
    AbortController.prototype.abort = function (reason) {
        if (this.signal.aborted) return;
        this.signal.aborted = true;
        this.signal.reason = reason === undefined ? new Error('This operation was aborted') : reason;
        this.signal.emit('abort');
        if (typeof this.signal.onabort === 'function') this.signal.onabort();
    };

    // ---- structuredClone ----------------------------------------------

    function structuredClone(value, seen) {
        if (value === null || typeof value !== 'object') return value;
        if (value instanceof Date) return new Date(value.getTime());
        if (value instanceof RegExp) return new RegExp(value.source, value.flags);
        if (!seen) seen = [];
        var idx = seen.indexOf(value);
        if (idx >= 0) return seen[idx + 1];
        if (Array.isArray(value)) {
            var arr = [];
            seen.push(value, arr);
            for (var i = 0; i < value.length; i++) arr.push(structuredClone(value[i], seen));
            return arr;
        }
        if (value instanceof Map) {
            var map = new Map();
            seen.push(value, map);
            value.forEach(function (v, k) { map.set(structuredClone(k, seen), structuredClone(v, seen)); });
            return map;
        }
        if (value instanceof Set) {
            var set = new Set();
            seen.push(value, set);
            value.forEach(function (v) { set.add(structuredClone(v, seen)); });
            return set;
        }
        var out = {};
        seen.push(value, out);
        var keys = Object.keys(value);
        for (var k = 0; k < keys.length; k++) out[keys[k]] = structuredClone(value[keys[k]], seen);
        return out;
    }

    // ---- fs streams ----------------------------------------------------

    function ReadStream(path, opts) {
        Readable.call(this);
        opts = opts || {};
        var rs = this;
        this.path = path;
        fsObj.readFile(path, opts.encoding || null, function (err, data) {
            if (err) { rs.emit('error', err); return; }
            var chunkSize = opts.highWaterMark || 64 * 1024;
            if (typeof data === 'string') {
                for (var i = 0; i < data.length; i += chunkSize) rs.push(data.slice(i, i + chunkSize));
            } else {
                for (var j = 0; j < data.length; j += chunkSize) rs.push(data.subarray(j, j + chunkSize));
            }
            rs.push(null);
        });
    }
    ReadStream.prototype = Object.create(Readable.prototype);
    ReadStream.prototype.constructor = ReadStream;

    function WriteStream(path, opts) {
        var chunks = [];
        Writable.call(this, {
            write: function (chunk, enc, cb) { chunks.push(chunk); cb(); },
            final: function (cb) {
                var data = typeof chunks[0] === 'string' ? chunks.join('') : chunks;
                fsObj.writeFile(path, data, function (err) { cb(err); });
            }
        });
        this.path = path;
    }
    WriteStream.prototype = Object.create(Writable.prototype);
    WriteStream.prototype.constructor = WriteStream;

    function createReadStream(path, opts) { return new ReadStream(path, opts); }
    function createWriteStream(path, opts) { return new WriteStream(path, opts); }
    fsObj.ReadStream = ReadStream;
    fsObj.WriteStream = WriteStream;
    fsObj.createReadStream = createReadStream;
    fsObj.createWriteStream = createWriteStream;

    g.EventEmitter = EventEmitter;
    g.events = EventEmitter;
    g.stream = streamModule;

    function consumeStream(stream) {
        return new Promise(function (resolve, reject) {
            var chunks = [];
            stream.on('data', function (chunk) {
                chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
            });
            stream.on('end', function () { resolve(Buffer.concat(chunks)); });
            stream.on('error', reject);
        });
    }
    g.streamConsumers = {
        buffer: function (stream) { return consumeStream(stream); },
        text: function (stream) {
            return consumeStream(stream).then(function (buf) { return buf.toString('utf8'); });
        },
        json: function (stream) {
            return consumeStream(stream).then(function (buf) { return JSON.parse(buf.toString('utf8')); });
        },
        arrayBuffer: function (stream) {
            return consumeStream(stream).then(function (buf) {
                return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
            });
        },
        blob: function (stream) {
            return consumeStream(stream).then(function (buf) { return new Blob([buf]); });
        }
    };
    g.ReadableStream = ReadableStream;
    g.WritableStream = WritableStream;
    g.TransformStream = TransformStream;
    g.stream_web = streamWebModule;
    g.url = urlModule;
    g.URL = URL;
    g.URLSearchParams = URLSearchParams;
    g.util = utilModule;
    g.timersPromises = timersPromises;
    g.AbortController = AbortController;
    g.AbortSignal = AbortSignal;
    g.structuredClone = structuredClone;


    // Async wrappers for the fd/link surface. The underlying syscalls are
    // blocking; the callback is deferred so callers see Node's async shape.
    function deferredCall(fn, args, cb) {
        queueMicrotask(function () {
            var value;
            try { value = fn.apply(undefined, args); }
            catch (e) { cb(e); return; }
            cb(null, value);
        });
    }
    fsObj.open = function (path, flags, mode, cb) {
        if (typeof mode === 'function') { cb = mode; mode = 438; }
        __djs.fs.openStart(path, flags, mode, cb);
    };
    fsObj.close = function (fd, cb) { deferredCall(fsObj.closeSync, [fd], cb); };
    fsObj.read = function (fd, buffer, offset, length, position, cb) {
        if (typeof position === 'function') { cb = position; position = null; }
        if (typeof length === 'function') { cb = length; length = undefined; position = null; }
        deferredCall(function () { return fsObj.readSync(fd, buffer, offset, length, position); }, [], cb);
    };
    fsObj.write = function (fd, data, offset, length, position, cb) {
        if (typeof position === 'function') { cb = position; position = null; }
        if (typeof length === 'function') { cb = length; length = undefined; position = null; }
        if (typeof offset === 'function') { cb = offset; offset = 0; length = undefined; position = null; }
        if (typeof data === 'string') {
            var enc = typeof position === 'string' ? position : 'utf8';
            var buf = Buffer.from(data, enc);
            var pos = typeof offset === 'number' ? offset : null;
            deferredCall(function () { return fsObj.writeSync(fd, buf, 0, buf.length, pos); }, [], function (err, n) { cb(err, n, buf); });
            return;
        }
        deferredCall(function () { return fsObj.writeSync(fd, data, offset, length, position); }, [], function (err, n) { cb(err, n, data); });
    };
    fsObj.fstat = function (fd, cb) { deferredCall(fsObj.fstatSync, [fd], cb); };
    fsObj.lstat = function (path, cb) { deferredCall(fsObj.lstatSync, [path], cb); };
    fsObj.chmod = function (path, mode, cb) { deferredCall(fsObj.chmodSync, [path, modeArg(mode)], cb); };
    fsObj.chown = function (path, uid, gid, cb) { deferredCall(fsObj.chownSync, [path, uid, gid], cb); };
    fsObj.link = function (from, to, cb) { deferredCall(fsObj.linkSync, [from, to], cb); };
    fsObj.symlink = function (target, path, cb) { deferredCall(fsObj.symlinkSync, [target, path], cb); };
    fsObj.readlink = function (path, cb) { deferredCall(fsObj.readlinkSync, [path], cb); };
    fsObj.truncate = function (path, len, cb) { deferredCall(fsObj.truncateSync, [path, len], cb); };
    fsObj.fsync = function (fd, cb) { deferredCall(fsObj.fsyncSync, [fd], cb); };
    fsObj.fdatasync = function (fd, cb) { deferredCall(fsObj.fdatasyncSync, [fd], cb); };
    fsObj.ftruncate = function (fd, len, cb) { deferredCall(fsObj.ftruncateSync, [fd, len], cb); };
    fsObj.fchmod = function (fd, mode, cb) { deferredCall(fsObj.fchmodSync, [fd, mode], cb); };
    fsObj.fchown = function (fd, uid, gid, cb) { deferredCall(fsObj.fchownSync, [fd, uid, gid], cb); };

    function FileHandle(fd) { this.fd = fd; }
    FileHandle.prototype.read = function (buffer, offset, length, position) {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.read(self.fd, buffer, offset, length, position, function (err, n) {
                if (err) reject(err); else resolve({ bytesRead: n, buffer: buffer });
            });
        });
    };
    FileHandle.prototype.write = function (data, offset, length, position) {
        var self = this;
        return new Promise(function (resolve, reject) {
            var cb = function (err, n, buf) {
                if (err) reject(err); else resolve({ bytesWritten: n, buffer: buf });
            };
            if (typeof data === 'string') fsObj.write(self.fd, data, offset, position, cb);
            else fsObj.write(self.fd, data, offset, length, position, cb);
        });
    };
    FileHandle.prototype.stat = function () {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.fstat(self.fd, function (err, st) { if (err) reject(err); else resolve(st); });
        });
    };
    FileHandle.prototype.truncate = function (len) {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.ftruncate(self.fd, len, function (err) { if (err) reject(err); else resolve(); });
        });
    };
    FileHandle.prototype.chmod = function (mode) {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.fchmod(self.fd, mode, function (err) { if (err) reject(err); else resolve(); });
        });
    };
    FileHandle.prototype.chown = function (uid, gid) {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.fchown(self.fd, uid, gid, function (err) { if (err) reject(err); else resolve(); });
        });
    };
    FileHandle.prototype.sync = function () {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.fsync(self.fd, function (err) { if (err) reject(err); else resolve(); });
        });
    };
    FileHandle.prototype.datasync = function () {
        var self = this;
        return new Promise(function (resolve, reject) {
            fsObj.fdatasync(self.fd, function (err) { if (err) reject(err); else resolve(); });
        });
    };
    FileHandle.prototype.readFile = function (options) {
        var self = this;
        var enc = encodingOf(options);
        return this.stat().then(function (st) {
            var buf = Buffer.alloc(st.size);
            return self.read(buf, 0, st.size, 0).then(function (r) {
                var out = buf.slice(0, r.bytesRead);
                return enc === undefined ? out : out.toString(enc);
            });
        });
    };
    FileHandle.prototype.writeFile = function (data, options) {
        var self = this;
        var buf = typeof data === 'string' ? Buffer.from(data, encodingOf(options) || 'utf8') : data;
        return new Promise(function (resolve, reject) {
            fsObj.write(self.fd, buf, 0, buf.length, null, function (err, n) {
                if (err) reject(err); else resolve(n);
            });
        });
    };
    FileHandle.prototype.close = function () {
        var self = this;
        if (this.fd < 0) return Promise.resolve();
        var fd = this.fd;
        this.fd = -1;
        return new Promise(function (resolve, reject) {
            fsObj.close(fd, function (err) {
                if (err) reject(err); else resolve();
            });
        });
    };

    fsPromises.open = function (path, flags, mode) {
        return new Promise(function (resolve, reject) {
            fsObj.open(path, flags, mode === undefined ? 438 : mode, function (err, fd) {
                if (err) reject(err); else resolve(new FileHandle(fd));
            });
        });
    };
    fsPromises.lstat = function (path) { return promiseOne(fsObj.lstat, [path]).then(function (raw) { return raw; }); };
    fsPromises.chmod = function (path, mode) { return promiseOne(fsObj.chmod, [path, mode]); };
    fsPromises.chown = function (path, uid, gid) { return promiseOne(fsObj.chown, [path, uid, gid]); };
    fsPromises.link = function (from, to) { return promiseOne(fsObj.link, [from, to]); };
    fsPromises.symlink = function (target, path) { return promiseOne(fsObj.symlink, [target, path]); };
    fsPromises.readlink = function (path) { return promiseOne(fsObj.readlink, [path]); };
    fsPromises.truncate = function (path, len) { return promiseOne(fsObj.truncate, [path, len]); };


    function TextEncoder() { this.encoding = 'utf-8'; }
    TextEncoder.prototype.encode = function (input) {
        return Buffer.from(input === undefined ? '' : String(input), 'utf8');
    };
    TextEncoder.prototype.encodeInto = function (input, dest) {
        var bytes = this.encode(input);
        var n = Math.min(bytes.length, dest.length);
        dest.set(bytes.subarray(0, n));
        return { read: input.length, written: n };
    };

    function TextDecoder(encoding) {
        this.encoding = (encoding || 'utf-8').toLowerCase();
        this.fatal = false;
        this.ignoreBOM = false;
    }
    TextDecoder.prototype.decode = function (input) {
        if (input === undefined || input === null) return '';
        var buf = Buffer.from(input);
        var enc = this.encoding === 'utf-8' || this.encoding === 'utf8' ? 'utf8' : this.encoding;
        return buf.toString(enc);
    };

    g.buffer = { Buffer: Buffer, constants: { MAX_LENGTH: 2147483647, MAX_STRING_LENGTH: 536870888 } };
    g.TextEncoder = TextEncoder;
    g.TextDecoder = TextDecoder;



    // ---- child_process (v0.8, synchronous) ----------------------------

    function spawnSync(file, args, options) {
        if (!Array.isArray(args)) { options = args; args = []; }
        if (options && typeof options === 'object' &&
            options.input !== undefined && options.input !== null &&
            typeof options.input !== 'string') {
            var o = {};
            for (var k in options) o[k] = options[k];
            o.input = Buffer.isBuffer(options.input)
                ? options.input.toString('utf8')
                : String(options.input);
            options = o;
        }
        var r = __djs.child.spawnSync(String(file), args || [], options || {});
        // Node's sync result: a signal death has status null and a named
        // signal; the engine reports 128 + number instead.
        if (r && typeof r.signal === 'number' && r.signal > 0) {
            var sig = r.signal;
            r.signal = signalNameOf(sig);
            if (r.status === 128 + sig) r.status = null;
        }
        return r;
    }
    // Node returns a string when an encoding is requested and a Buffer
    // otherwise; ignoring `encoding` silently handed callers the wrong type.
    function syncOutput(text, options) {
        var enc = options && options.encoding;
        if (enc && enc !== 'buffer')
            return typeof text === 'string' ? text : Buffer.from(text).toString(enc);
        return Buffer.from(text);
    }
    function execFileSync(file, args, options) {
        var r = spawnSync(file, args, options);
        if (r.error) { r.error.stdout = r.stdout; r.error.stderr = r.stderr; r.error.status = r.status; throw r.error; }
        if (r.status !== 0) {
            var e = new Error('Command failed: ' + file);
            e.status = r.status; e.stderr = r.stderr; e.stdout = r.stdout;
            throw e;
        }
        return syncOutput(r.stdout, options);
    }
    function execSync(command, options) {
        var r = spawnSync("sh", ["-c", String(command)], options || {});
        if (r.error) { r.error.stdout = r.stdout; r.error.stderr = r.stderr; r.error.status = r.status; throw r.error; }
        if (r.status !== 0) {
            var e = new Error('Command failed: ' + command);
            e.status = r.status; e.stderr = r.stderr; e.stdout = r.stdout;
            throw e;
        }
        return syncOutput(r.stdout, options);
    }

    // Node's stdio pipes emit 'close' when the child closes, even when nobody
    // read the data. Without that, stream.finished() on an unconsumed
    // child.stdout waits for an 'end' that is deferred while data is buffered,
    // and never settles. The engine drains the pipes before the exit callback,
    // so no data is lost by closing here.
    // Node reports `signalCode` as a name ("SIGTERM") and `exitCode` as null
    // when the child died from a signal; packages (human-signals, execa) look
    // the name up in a table.
    var SIGNAL_NAMES = {
        1: 'SIGHUP', 2: 'SIGINT', 3: 'SIGQUIT', 4: 'SIGILL', 5: 'SIGTRAP',
        6: 'SIGABRT', 7: 'SIGBUS', 8: 'SIGFPE', 9: 'SIGKILL', 10: 'SIGUSR1',
        11: 'SIGSEGV', 12: 'SIGUSR2', 13: 'SIGPIPE', 14: 'SIGALRM',
        15: 'SIGTERM', 17: 'SIGCHLD', 18: 'SIGCONT', 19: 'SIGSTOP',
        20: 'SIGTSTP', 21: 'SIGTTIN', 22: 'SIGTTOU', 23: 'SIGURG',
        24: 'SIGXCPU', 25: 'SIGXFSZ', 26: 'SIGVTALRM', 27: 'SIGPROF',
        28: 'SIGWINCH', 29: 'SIGIO', 30: 'SIGPWR', 31: 'SIGSYS',
    };
    function signalNameOf(number) {
        return SIGNAL_NAMES[number] || ('SIG' + number);
    }

    function finishStdio(stream) {
        if (!stream) return;
        stream.push(null);
        if (!stream.destroyed) stream.destroy();
    }

    function ChildProcess() {
        EventEmitter.call(this);
        this.pid = undefined;
        this.exitCode = null;
        this.signalCode = null;
        this.killed = false;
        this.stdout = new Readable();
        this.stderr = new Readable();
        var self = this;
        // A real Writable, not a bare {write, end}: packages call
        // stdin.destroy(), listen for 'close' and pass it to
        // stream.finished(), all of which need the EventEmitter surface.
        this.stdin = new streamModule.Writable({
            write: function (chunk, enc, cb) {
                if (!self._id) { cb(); return; }
                var s = typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');
                __djs.child.write(self._id, s);
                cb();
            },
            final: function (cb) {
                if (self._id) __djs.child.end(self._id);
                cb();
            }
        });
        var rawStdinWrite = this.stdin.write;
        this.stdin.write = function (chunk, enc, cb) {
            if (!self._id) {
                // The child is gone: discard, as Node does, and keep the
                // documented `false` return instead of throwing.
                if (typeof enc === 'function') enc();
                else if (typeof cb === 'function') cb();
                return false;
            }
            return rawStdinWrite.call(this, chunk, enc, cb);
        };
        // Node exposes the three standard streams here; packages (execa among
        // them) treat `stdio === undefined` as "the spawn failed" and wait for
        // an 'error' event that will never come.
        this.stdio = [this.stdin, this.stdout, this.stderr];
        this._id = 0;
    }
    ChildProcess.prototype = Object.create(EventEmitter.prototype);
    ChildProcess.prototype.constructor = ChildProcess;
    ChildProcess.prototype.kill = function (sig) {
        if (!this._id) return false;
        var ok = __djs.child.kill(this._id, sig === undefined ? 'SIGTERM' : sig);
        if (ok !== false) this.killed = true;
        return true;
    };

    function spawnInto(cp, file, args, options) {
        options = options || {};
        if (options.env && !options._env) {
            var envList = [];
            for (var ek in options.env) envList.push(ek + "=" + options.env[ek]);
            var copy = {};
            for (var ck in options) copy[ck] = options[ck];
            copy._env = envList;
            options = copy;
        }
        var id = __djs.child.spawn(String(file), args || [], options);
        cp._id = id;
        cp.pid = __djs.child.pid(id);
        __djs.child.onData(id, function (fd, chunk) {
            var stream = fd === 1 ? cp.stdout : cp.stderr;
            stream.push(Buffer.from(chunk));
        });
        __djs.child.onExit(id, function (code, signal) {
            // Release the handle before user handlers run: a write or kill in
            // an exit/close listener must not reach the dead child.
            cp._id = 0;
            // Node: a signal death has exitCode null and a named signalCode.
            cp.exitCode = signal ? null : code;
            cp.signalCode = signal ? signalNameOf(signal) : null;
            if (cp.stdin && !cp.stdin.writableEnded) cp.stdin.end();
            cp.emit('exit', cp.exitCode, cp.signalCode);
            finishStdio(cp.stdout);
            finishStdio(cp.stderr);
            cp.emit('close', cp.exitCode, cp.signalCode);
        });
        // Node emits 'spawn' asynchronously, once the child exists and before
        // any stdio data. Packages (execa among them) await it before waiting
        // for exit, so a missing event hangs the whole call.
        if (!cp.spawnEmitted) {
            cp.spawnEmitted = true;
            queueMicrotask(function () { cp.emit('spawn'); });
        }
        return cp;
    }
    function spawn(file, args, options) {
        if (!Array.isArray(args)) { options = args; args = []; }
        return spawnInto(new ChildProcess(), file, args, options || {});
    }

    function fork(modulePath, args, options) {
        if (!Array.isArray(args)) { options = args; args = []; }
        options = options || {};
        args = args || [];
        var cp = new ChildProcess();
        cp.connected = false;
        var queue = [], sock = null, token = String(Math.random()).slice(2);
        cp.send = function (message, cb) {
            var line = JSON.stringify(message) + "\n";
            if (cp.connected && sock) sock.write(line);
            else queue.push(line);
            if (cb) queueMicrotask(function () { cb(null); });
            return true;
        };
        cp.disconnect = function () {
            if (sock) { sock.end(); sock = null; cp.connected = false; }
        };
        var buffer = "", authed = false;
        var server = netModule.createServer(function (conn) {
            if (authed) { conn.destroy(); return; }
            conn.on("data", function (chunk) {
                buffer += chunk.toString("utf8");
                var idx;
                while ((idx = buffer.indexOf("\n")) >= 0) {
                    var line = buffer.slice(0, idx);
                    buffer = buffer.slice(idx + 1);
                    if (!line) continue;
                    var msg;
                    try { msg = JSON.parse(line); } catch (e) { continue; }
                    if (!authed) {
                        if (msg && msg.token === token) {
                            authed = true;
                            sock = conn;
                            cp.connected = true;
                            while (queue.length) conn.write(queue.shift());
                        }
                        continue;
                    }
                    cp.emit("message", msg);
                }
            });
        });
        server.listen(0, "127.0.0.1", function () {
            var opts = {};
            for (var ok in options) opts[ok] = options[ok];
            var env = {};
            var base = options.env || process.env;
            for (var ek in base) env[ek] = base[ek];
            env.DJS_IPC_PORT = String(server.address().port);
            env.DJS_IPC_TOKEN = token;
            opts.env = env;
            spawnInto(cp, process.execPath, ["--allow-net", "--allow-listen", "--allow-env", String(modulePath)].concat(args), opts);
        });
        cp.on("close", function () { try { server.close(); } catch (e) {} });
        return cp;
    }

    function collect(stream, state) {
        stream.on('data', function (chunk) {
            state.size += chunk.length;
            if (state.size > state.maxBuffer) {
                state.overflow = true;
                if (state.child._id) state.child.kill(state.killSignal);
                return;
            }
            state.chunks.push(Buffer.from(chunk));
        });
    }

    function execFile(file, args, options, callback) {
        if (typeof args === 'function') { callback = args; args = []; options = {}; }
        else if (typeof options === 'function') { callback = options; options = {}; }
        args = args || []; options = options || {};
        var encoding = options.encoding === undefined ? 'utf8' : options.encoding;
        var maxBuffer = options.maxBuffer === undefined ? 1024 * 1024 : options.maxBuffer;
        var killSignal = options.killSignal || 'SIGTERM';
        var child = spawn(file, args, options);
        var out = { chunks: [], size: 0, maxBuffer: maxBuffer, overflow: false, child: child, killSignal: killSignal };
        var errOut = { chunks: [], size: 0, maxBuffer: maxBuffer, overflow: false, child: child, killSignal: killSignal };
        collect(child.stdout, out);
        collect(child.stderr, errOut);
        var timer = null, timedOut = false, settled = false;
        if (options.timeout) {
            timer = setTimeout(function () {
                timedOut = true;
                child.killed = true;
                if (child._id) child.kill(killSignal);
            }, options.timeout);
        }
        function decode(state) {
            var buf = Buffer.concat(state.chunks);
            return encoding === 'buffer' ? buf : buf.toString(encoding);
        }
        child.on('close', function (code, signal) {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            var stdout = decode(out), stderr = decode(errOut);
            var err = null;
            if (out.overflow || errOut.overflow) {
                err = new Error('maxBuffer exceeded');
                err.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
                err.killed = true;
                err.signal = signal;
                err.cmd = file + ' ' + args.join(' ');
                err.stdout = stdout;
                err.stderr = stderr;
            } else if (timedOut) {
                err = new Error('Command timed out');
                err.code = 'ETIMEDOUT';
                err.killed = true;
                err.signal = signal;
                err.cmd = file + ' ' + args.join(' ');
                err.stdout = stdout;
                err.stderr = stderr;
            } else if (code !== 0) {
                err = new Error('Command failed: ' + file + ' ' + args.join(' ') + '\n' + stderr);
                err.code = code;
                err.killed = child.killed;
                err.signal = signal;
                err.cmd = file + ' ' + args.join(' ');
                err.stdout = stdout;
                err.stderr = stderr;
            }
            if (callback) callback(err, stdout, stderr);
        });
        return child;
    }

    function exec(command, options, callback) {
        if (typeof options === 'function') { callback = options; options = {}; }
        options = options || {};
        var shell = options.shell || '/bin/sh';
        return execFile(shell, ['-c', String(command)], options, callback);
    }

    var childProcessModule = {
        ChildProcess: ChildProcess,
        spawn: spawn,
        spawnSync: spawnSync,
        exec: exec,
        execFile: execFile,
        fork: fork,
        execSync: execSync,
        execFileSync: execFileSync
    };

    // ---- net / dns -----------------------------------------------------

    function Socket(opts) {
        Duplex.call(this, opts);
        this._id = 0;
        this.connecting = false;
        this._reading = false;
        this.remoteAddress = undefined;
        this.remotePort = undefined;
        this.localPort = undefined;
        this._readableState = { endEmitted: false, flowing: true, length: 0, objectMode: false };
        this._writableState = { ended: false, finished: false };
    }
    Socket.prototype = Object.create(Duplex.prototype);
    Socket.prototype.constructor = Socket;
    Socket.prototype._read = function () {
        if (this._reading || !this._id || this.destroyed) return;
        this._reading = true;
        var self = this;
        __djs.net.startRead(this._id, function (err, data) {
            if (self.destroyed) return;
            if (err) { self.emit('error', err); self.destroy(); return; }
            if (data === null) {
                self.push(null);
                self.destroy();
                return;
            }
            self.push(new Buffer(data));
        });
    };
    Socket.prototype._write = function (chunk, enc, cb) {
        if (!this._id || this.destroyed) {
            var err = new Error('socket is not connected');
            err.code = 'ERR_SOCKET_CLOSED';
            cb(err);
            return;
        }
        var buf = typeof chunk === 'string' ? Buffer.from(chunk, enc || 'utf8') : chunk;
        __djs.net.write(this._id, buf, function (err) { cb(err || undefined); });
    };
    Socket.prototype._final = function (cb) {
        if (this._id && !this.destroyed) __djs.net.end(this._id);
        cb();
    };
    Socket.prototype.connect = function (port, host, cb) {
        if (typeof port === 'object' && port !== null) {
            var o = port;
            cb = host;
            host = o.host || o.hostname || 'localhost';
            port = o.port;
        }
        if (typeof host === 'function') { cb = host; host = 'localhost'; }
        if (typeof host !== 'string') host = 'localhost';
        var self = this;
        this.connecting = true;
        __djs.net.connect(host, Number(port), function (err, id) {
            if (self.destroyed) return;
            self.connecting = false;
            if (err) {
                self.emit('error', err);
                if (cb) cb(err);
                return;
            }
            self._id = id;
            self.remoteAddress = host;
            self.remotePort = Number(port);
            self.emit('connect');
            if (cb) cb();
            self._read();
        });
        return this;
    };
    Socket.prototype.destroy = function (err) {
        if (this.destroyed) return this;
        this.destroyed = true;
        if (this._timer) { clearTimeout(this._timer); this._timer = null; }
        if (this._id) { __djs.net.close(this._id); this._id = 0; }
        if (err) this.emit('error', err);
        this.emit('close');
        return this;
    };
    Socket.prototype.cork = function () { this._corked = true; return this; };
    Socket.prototype.uncork = function () { this._corked = false; return this; };
    Socket.prototype.setNoDelay = function () { return this; };
    Socket.prototype.setKeepAlive = function () { return this; };
    Socket.prototype.setTimeout = function (ms, cb) {
        var self = this;
        if (this._timer) clearTimeout(this._timer);
        if (ms > 0) this._timer = setTimeout(function () {
            self.emit('timeout');
            if (cb) cb();
        }, ms);
        return this;
    };

    function connect(port, host, cb) {
        var s = new Socket();
        return s.connect(port, host, cb);
    }


    // ---- net.Server ---------------------------------------------------
    function Server(opts, onConn) {
        EventEmitter.call(this);
        if (typeof opts === 'function') { onConn = opts; opts = {}; }
        this._id = 0;
        this._host = '127.0.0.1';
        this.port = 0;
        this.listening = false;
        if (onConn) this.on('connection', onConn);
    }
    Server.prototype = Object.create(EventEmitter.prototype);
    Server.prototype.constructor = Server;
    Server.prototype.listen = function (port, host, cb) {
        var reusePort = false;
        if (typeof port === 'object' && port !== null) {
            var o = port;
            port = o.port;
            host = o.host || o.hostname;
            reusePort = !!o.reusePort;
        }
        if (typeof host === 'function') { cb = host; host = undefined; }
        if (process.env.DJS_CLUSTER_WORKER) reusePort = true;
        this._host = host || '127.0.0.1';
        var self = this;
        var id = __djs.net.listen(String(this._host), Number(port) || 0, function (connId) {
            var s = new Socket();
            s._id = connId;
            s.connected = true;
            self.emit('connection', s);
            s._read();
        }, reusePort);
        this._id = id;
        this.port = __djs.net.listenerPort(id);
        this.listening = true;
        var self2 = this;
        queueMicrotask(function () {
            self2.emit('listening');
            if (cb) cb();
        });
        return this;
    };
    Server.prototype.address = function () {
        return this.listening ? {
            address: this._host,
            family: this._host && this._host.indexOf(':') >= 0 ? 'IPv6' : 'IPv4',
            port: this.port
        } : null;
    };
    Server.prototype.close = function (cb) {
        if (this._id) { __djs.net.closeListener(this._id); this._id = 0; }
        this.listening = false;
        var self = this;
        queueMicrotask(function () { self.emit('close'); if (cb) cb(); });
        return this;
    };

    var netModule = {
        Socket: Socket,
        Server: Server,
        createServer: function (opts, cb) { return new Server(opts, cb); },
        connect: connect,
        createConnection: connect,
        isIP: function (v) { return /^[0-9.]+$/.test(v) ? 4 : (v.indexOf(':') >= 0 ? 6 : 0); },
        isIPv4: function (v) { return /^[0-9.]+$/.test(v); },
        isIPv6: function (v) { return v.indexOf(':') >= 0; }
    };

    // ---- DNS wire client (MX/TXT/SRV/CNAME/NS/SOA/PTR) -----------------
    var dnsConfiguredServers = null;
    function dnsParseServer(entry) {
        var host = String(entry), port = 53;
        var m = /^\[([^\]]+)\](?::(\d+))?$/.exec(host);
        if (m) return { host: m[1], port: m[2] ? Number(m[2]) : 53, family: 6 };
        var idx = host.lastIndexOf(':');
        if (idx > 0 && host.indexOf(':') === idx) {
            port = Number(host.slice(idx + 1)) || 53;
            host = host.slice(0, idx);
        }
        return { host: host, port: port, family: host.indexOf(':') !== -1 ? 6 : 4 };
    }
    function dnsServers() {
        if (dnsConfiguredServers) return dnsConfiguredServers;
        var list = [];
        try {
            var text = Buffer.from(__djs.fs.readFileSync('/etc/resolv.conf', false)).toString('utf8');
            var lines = text.split('\n');
            for (var i = 0; i < lines.length; i++) {
                var m = /^\s*nameserver\s+(\S+)/.exec(lines[i]);
                if (m) list.push(dnsParseServer(m[1]));
            }
        } catch (e) { /* fall through */ }
        if (!list.length) list.push({ host: '127.0.0.1', port: 53, family: 4 });
        dnsConfiguredServers = list;
        return list;
    }
    function dnsEncodeName(name) {
        var labels = String(name).replace(/\.$/, '').split('.');
        var parts = [];
        for (var i = 0; i < labels.length; i++) {
            var b = Buffer.from(labels[i], 'utf8');
            if (!b.length || b.length > 63) throw new Error('invalid DNS name');
            parts.push(Buffer.from([b.length]), b);
        }
        parts.push(Buffer.from([0]));
        return Buffer.concat(parts);
    }
    function dnsBuildQuery(id, name, type) {
        var head = Buffer.alloc(12);
        head.writeUInt16BE(id, 0);
        head.writeUInt16BE(0x0100, 2); // recursion desired
        head.writeUInt16BE(1, 4);
        var tail = Buffer.alloc(4);
        tail.writeUInt16BE(type, 0);
        tail.writeUInt16BE(1, 2);
        return Buffer.concat([head, dnsEncodeName(name), tail]);
    }
    function dnsReadName(buf, start) {
        var labels = [], off = start, next = start, jumped = false, hops = 0;
        for (;;) {
            if (off >= buf.length) throw new Error('truncated DNS name');
            var len = buf[off];
            if (len === 0) { off++; break; }
            if ((len & 0xC0) === 0xC0) {
                if (off + 1 >= buf.length) throw new Error('truncated DNS pointer');
                var ptr = ((len & 0x3F) << 8) | buf[off + 1];
                if (!jumped) next = off + 2;
                off = ptr; jumped = true;
                if (++hops > 32) throw new Error('DNS pointer loop');
                continue;
            }
            off++;
            if (off + len > buf.length) throw new Error('truncated DNS label');
            labels.push(buf.slice(off, off + len).toString('utf8'));
            off += len;
        }
        return { name: labels.join('.'), next: jumped ? next : off };
    }
    // RFC 5952: Node prints AAAA records with the longest zero run compressed.
    function formatIpv6(groups) {
        var bestStart = -1, bestLen = 0, curStart = -1, curLen = 0;
        for (var i = 0; i < 8; i++) {
            if (groups[i] === 0) {
                if (curStart < 0) { curStart = i; curLen = 0; }
                curLen += 1;
                if (curLen > bestLen) { bestLen = curLen; bestStart = curStart; }
            } else { curStart = -1; curLen = 0; }
        }
        var hex = groups.map(function (g) { return g.toString(16); });
        if (bestLen < 2) return hex.join(':');
        return hex.slice(0, bestStart).join(':') + '::' + hex.slice(bestStart + bestLen).join(':');
    }

    function dnsParseResponse(buf, expectId) {
        if (buf.length < 12) throw new Error('short DNS response');
        if (buf.readUInt16BE(0) !== expectId) throw new Error('DNS id mismatch');
        var flags = buf.readUInt16BE(2);
        var rcode = flags & 0x0F;
        var qd = buf.readUInt16BE(4), an = buf.readUInt16BE(6);
        var off = 12;
        for (var q = 0; q < qd; q++) { off = dnsReadName(buf, off).next + 4; }
        var out = [];
        for (var i = 0; i < an; i++) {
            var rr = dnsReadName(buf, off);
            off = rr.next;
            if (off + 10 > buf.length) throw new Error('truncated DNS record');
            var type = buf.readUInt16BE(off);
            var rdlen = buf.readUInt16BE(off + 8);
            var rd = off + 10;
            if (rd + rdlen > buf.length) throw new Error('truncated DNS rdata');
            if (type === 1 && rdlen === 4) {
                out.push(buf[rd] + '.' + buf[rd + 1] + '.' + buf[rd + 2] + '.' + buf[rd + 3]);
            } else if (type === 28 && rdlen === 16) {
                var groups = [];
                for (var g = 0; g < 8; g++) groups.push(buf.readUInt16BE(rd + g * 2));
                out.push(formatIpv6(groups));
            } else if (type === 15) {
                out.push({ priority: buf.readUInt16BE(rd), exchange: dnsReadName(buf, rd + 2).name });
            } else if (type === 16) {
                var txt = [], p = rd, end = rd + rdlen;
                while (p < end) { var l = buf[p++]; txt.push(buf.slice(p, Math.min(p + l, end)).toString('utf8')); p += l; }
                out.push(txt);
            } else if (type === 33) {
                out.push({
                    priority: buf.readUInt16BE(rd), weight: buf.readUInt16BE(rd + 2),
                    port: buf.readUInt16BE(rd + 4), name: dnsReadName(buf, rd + 6).name
                });
            } else if (type === 2 || type === 5 || type === 12) {
                out.push(dnsReadName(buf, rd).name);
            } else if (type === 6) {
                var soa = dnsReadName(buf, rd);
                var hm = dnsReadName(buf, soa.next);
                out.push({
                    nsname: soa.name, hostmaster: hm.name,
                    serial: buf.readUInt32BE(hm.next), refresh: buf.readUInt32BE(hm.next + 4),
                    retry: buf.readUInt32BE(hm.next + 8), expire: buf.readUInt32BE(hm.next + 12),
                    minttl: buf.readUInt32BE(hm.next + 16)
                });
            }
            off = rd + rdlen;
        }
        return { rcode: rcode, records: out };
    }
    // resolveAny asks for qtype 255 and reports every answer record with its
    // type attached. Node's shape is followed field for field (and in the same
    // key order); `ttl` is only carried on address records, as in Node.
    function dnsParseAny(buf, expectId) {
        if (buf.length < 12) throw new Error('short DNS response');
        if (buf.readUInt16BE(0) !== expectId) throw new Error('DNS id mismatch');
        var flags = buf.readUInt16BE(2);
        var rcode = flags & 0x0F;
        var qd = buf.readUInt16BE(4), an = buf.readUInt16BE(6);
        var off = 12;
        for (var q = 0; q < qd; q++) off = dnsReadName(buf, off).next + 4;
        var out = [];
        for (var i = 0; i < an; i++) {
            var rr = dnsReadName(buf, off);
            off = rr.next;
            if (off + 10 > buf.length) throw new Error('truncated DNS record');
            var type = buf.readUInt16BE(off);
            var ttl = buf.readUInt32BE(off + 4);
            var rdlen = buf.readUInt16BE(off + 8);
            var rd = off + 10;
            if (rd + rdlen > buf.length) throw new Error('truncated DNS rdata');
            if (type === 1 && rdlen === 4) {
                out.push({ address: buf[rd] + '.' + buf[rd + 1] + '.' + buf[rd + 2] + '.' + buf[rd + 3], ttl: ttl, type: 'A' });
            } else if (type === 28 && rdlen === 16) {
                var groups = [];
                for (var g = 0; g < 8; g++) groups.push(buf.readUInt16BE(rd + g * 2));
                out.push({ address: formatIpv6(groups), ttl: ttl, type: 'AAAA' });
            } else if (type === 2) {
                out.push({ value: dnsReadName(buf, rd).name, type: 'NS' });
            } else if (type === 5) {
                out.push({ value: dnsReadName(buf, rd).name, type: 'CNAME' });
            } else if (type === 12) {
                out.push({ value: dnsReadName(buf, rd).name, type: 'PTR' });
            } else if (type === 15) {
                out.push({ exchange: dnsReadName(buf, rd + 2).name, priority: buf.readUInt16BE(rd), type: 'MX' });
            } else if (type === 16) {
                var txt = [], p = rd, end = rd + rdlen;
                while (p < end) { var l = buf[p++]; txt.push(buf.slice(p, Math.min(p + l, end)).toString('utf8')); p += l; }
                out.push({ entries: txt, type: 'TXT' });
            } else if (type === 33) {
                out.push({
                    name: dnsReadName(buf, rd + 6).name, port: buf.readUInt16BE(rd + 4),
                    priority: buf.readUInt16BE(rd), weight: buf.readUInt16BE(rd + 2), type: 'SRV'
                });
            } else if (type === 6) {
                var soa = dnsReadName(buf, rd);
                var hm = dnsReadName(buf, soa.next);
                out.push({
                    nsname: soa.name, hostmaster: hm.name,
                    serial: buf.readUInt32BE(hm.next), refresh: buf.readUInt32BE(hm.next + 4),
                    retry: buf.readUInt32BE(hm.next + 8), expire: buf.readUInt32BE(hm.next + 12),
                    minttl: buf.readUInt32BE(hm.next + 16), type: 'SOA'
                });
            } else if (type === 257) {
                var critical = buf[rd], tagLen = buf[rd + 1];
                var tag = buf.slice(rd + 2, rd + 2 + tagLen).toString('utf8');
                var caa = { critical: critical, type: 'CAA' };
                caa[tag] = buf.slice(rd + 2 + tagLen, rd + rdlen).toString('utf8');
                out.push(caa);
            } else if (type === 35) {
                var nOrder = buf.readUInt16BE(rd), nPref = buf.readUInt16BE(rd + 2);
                var np = rd + 4, nStrings = [];
                for (var ns = 0; ns < 3; ns++) {
                    var nLen = buf[np++];
                    nStrings.push(buf.slice(np, np + nLen).toString('utf8'));
                    np += nLen;
                }
                var nFlags = nStrings[0], nService = nStrings[1], nRegexp = nStrings[2];
                out.push({
                    flags: nFlags, service: nService, regexp: nRegexp,
                    replacement: dnsReadName(buf, np).name, order: nOrder, preference: nPref, type: 'NAPTR'
                });
            }
            off = rd + rdlen;
        }
        return { rcode: rcode, records: out };
    }
    function dnsQuery(name, type, cb) {
        var servers = dnsServers();
        var index = 0;
        var id = Math.floor(Math.random() * 65536);
        var packet = dnsBuildQuery(id, name, type);
        function attempt() {
            if (index >= servers.length) {
                var e = new Error('query ENOTFOUND ' + name);
                e.code = 'ENOTFOUND';
                cb(e); return;
            }
            var server = servers[index++];
            var socket = new DgramSocket({ type: server.family === 6 ? 'udp6' : 'udp4' });
            var done = false;
            var timer = setTimeout(function () {
                var err = new Error('DNS query timed out');
                err.code = 'ETIMEOUT';
                finish(err);
            }, 2000);
            function finish(err, result) {
                if (done) return;
                done = true;
                clearTimeout(timer);
                try { socket.close(); } catch (e2) { /* ignore */ }
                if (err && index < servers.length) { attempt(); return; }
                cb(err || null, result);
            }
            socket.on('message', function (msg) {
                try {
                    var parsed = (type === 255 ? dnsParseAny : dnsParseResponse)(msg, id);
                    if (parsed.rcode === 3) {
                        var nf = new Error('query ENOTFOUND ' + name);
                        nf.code = 'ENOTFOUND';
                        finish(nf); return;
                    }
                    if (parsed.rcode !== 0) {
                        var be = new Error('DNS server returned rcode ' + parsed.rcode);
                        be.code = 'EBADRESP';
                        finish(be); return;
                    }
                    finish(null, parsed.records);
                } catch (e) { finish(e); }
            });
            socket.on('error', function (err) { finish(err); });
            socket.bind(0, '0.0.0.0', function () {
                try { socket.send(packet, server.port, server.host); }
                catch (e) { finish(e); }
            });
        }
        attempt();
    }
    function dnsResolveRecords(host, type, cb) {
        dnsQuery(String(host), type, function (err, records) { cb(err || null, records || []); });
    }
    function dnsPromise(host, type) {
        return new Promise(function (resolve, reject) {
            dnsResolveRecords(host, type, function (err, records) {
                if (err) reject(err); else resolve(records);
            });
        });
    }

    // Node's dns.reverse() turns the address into a PTR name; IPv6 has to be
    // expanded to 32 nibbles (no embedded-IPv4 shorthand).
    function dnsReverseName(ip) {
        var v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
        if (v4) {
            var octets = [v4[1], v4[2], v4[3], v4[4]];
            for (var i = 0; i < 4; i++) if (Number(octets[i]) > 255) return null;
            return octets.reverse().join('.') + '.in-addr.arpa';
        }
        if (ip.indexOf(':') < 0) return null;
        var halves = ip.split('::');
        if (halves.length > 2) return null;
        var head = halves[0] ? halves[0].split(':') : [];
        var tail = (halves.length === 2 && halves[1]) ? halves[1].split(':') : [];
        var groups;
        if (halves.length === 2) {
            var fill = 8 - head.length - tail.length;
            if (fill < 1) return null;
            var zeros = [];
            for (var z = 0; z < fill; z++) zeros.push('0');
            groups = head.concat(zeros).concat(tail);
        } else groups = head;
        if (groups.length !== 8) return null;
        var hex = '';
        for (var g = 0; g < 8; g++) {
            var h = ('0000' + groups[g].toLowerCase()).slice(-4);
            if (!/^[0-9a-f]{4}$/.test(h)) return null;
            hex += h;
        }
        return hex.split('').reverse().join('.') + '.ip6.arpa';
    }
    function dnsReverseError(ip) {
        var e = new Error('getHostByAddr EINVAL ' + ip);
        e.code = 'EINVAL';
        return e;
    }

    function dnsIsIpLiteral(text) {
        if (/^\d{1,3}(\.\d{1,3}){3}$/.test(text)) return true;
        return text.indexOf(":") !== -1;
    }
    // Node validates both arguments synchronously, in the callback and the
    // promise form alike, so the same checks run before any request is made.
    function dnsServicePort(address, port) {
        if (typeof address !== "string" || !dnsIsIpLiteral(address)) {
            var bad = new TypeError("The argument 'address' is invalid. Received " + String(address));
            bad.code = "ERR_INVALID_ARG_VALUE";
            throw bad;
        }
        if (typeof port !== "number" || !Number.isInteger(port) || port < 0 || port > 65535) {
            var range = new RangeError("Port should be >= 0 and < 65536. Received " + String(port));
            range.code = "ERR_SOCKET_BAD_PORT";
            throw range;
        }
        return port;
    }

    var dnsModule = {
        lookup: function (host, options, cb) {
            if (typeof options === 'function') { cb = options; options = {}; }
            try {
                __djs.net.lookupStart(String(host), function (err, addr, family) {
                    if (err) cb(err); else cb(null, addr, family);
                });
            } catch (e) {
                queueMicrotask(function () { cb(e); });
            }
        },
        lookupService: function (address, port, cb) {
            var p = dnsServicePort(address, port);
            __djs.net.lookupService(address, p, function (err, hostname, service) {
                if (err) cb(err); else cb(null, hostname, service);
            });
        },
        resolveAny: function (host, cb) {
            dnsQuery(String(host), 255, function (err, records) {
                if (err) { cb(err); return; }
                if (!records || !records.length) {
                    var e = new Error('query ENODATA ' + host);
                    e.code = 'ENODATA';
                    cb(e); return;
                }
                cb(null, records);
            });
        },
        resolve4: function (host, cb) { dnsResolveRecords(host, 1, cb); },
        resolve6: function (host, cb) { dnsResolveRecords(host, 28, cb); },
        resolveMx: function (host, cb) { dnsResolveRecords(host, 15, cb); },
        resolveTxt: function (host, cb) { dnsResolveRecords(host, 16, cb); },
        resolveSrv: function (host, cb) { dnsResolveRecords(host, 33, cb); },
        resolveCname: function (host, cb) { dnsResolveRecords(host, 5, cb); },
        resolveNs: function (host, cb) { dnsResolveRecords(host, 2, cb); },
        resolvePtr: function (host, cb) { dnsResolveRecords(host, 12, cb); },
        resolveSoa: function (host, cb) {
            dnsResolveRecords(host, 6, function (err, list) { cb(err || null, list && list[0]); });
        },
        resolve: function (host, type, cb) {
            if (typeof type === 'function') { cb = type; type = 'A'; }
            var t = String(type).toUpperCase();
            var map = { A: 1, AAAA: 28, MX: 15, TXT: 16, SRV: 33, CNAME: 5, NS: 2, PTR: 12, SOA: 6 };
            if (!map[t]) {
                queueMicrotask(function () { var e = new Error('unsupported record type ' + t); e.code = 'ENOTSUP'; cb(e); });
                return;
            }
            if (t === 'A' || t === 'AAAA') {
                dnsResolveRecords(host, t === 'A' ? 1 : 28, cb);
                return;
            }
            dnsResolveRecords(host, map[t], cb);
        },
        reverse: function (ip, cb) {
            var name = dnsReverseName(String(ip));
            if (!name) { queueMicrotask(function () { cb(dnsReverseError(ip)); }); return; }
            dnsResolveRecords(name, 12, cb);
        },
        setServers: function (servers) {
            if (!Array.isArray(servers) || !servers.length) {
                var e = new Error('servers must be a non-empty array'); e.code = 'ERR_INVALID_ARG_VALUE'; throw e;
            }
            dnsConfiguredServers = servers.map(dnsParseServer);
            return undefined;
        },
        getServers: function () { return dnsServers().map(function (s) { return s.host + ':' + s.port; }); },
        promises: {
            lookupService: function (address, port) {
                var p = dnsServicePort(address, port);
                return new Promise(function (resolve, reject) {
                    __djs.net.lookupService(address, p, function (err, hostname, service) {
                        if (err) reject(err); else resolve({ hostname: hostname, service: service });
                    });
                });
            },
            resolveAny: function (host) {
                return new Promise(function (resolve, reject) {
                    dnsModule.resolveAny(host, function (err, list) {
                        if (err) reject(err); else resolve(list);
                    });
                });
            },
            lookup: function (host) {
                return new Promise(function (resolve, reject) {
                    dnsModule.lookup(host, {}, function (err, addr, family) {
                        if (err) reject(err); else resolve({ address: addr, family: family });
                    });
                });
            },
            resolve4: function (host) { return dnsPromise(host, 1); },
            resolve6: function (host) { return dnsPromise(host, 28); },
            resolveSoa: function (host) {
                // Node's promise form resolves a single SOA object, not an array.
                return dnsPromise(host, 6).then(function (list) { return list && list[0]; });
            },
            resolveMx: function (host) { return dnsPromise(host, 15); },
            resolveTxt: function (host) { return dnsPromise(host, 16); },
            resolveSrv: function (host) { return dnsPromise(host, 33); },
            resolveCname: function (host) { return dnsPromise(host, 5); },
            resolveNs: function (host) { return dnsPromise(host, 2); },
            resolvePtr: function (host) { return dnsPromise(host, 12); },
            reverse: function (ip) {
                var name = dnsReverseName(String(ip));
                if (!name) return Promise.reject(dnsReverseError(ip));
                return dnsPromise(name, 12);
            },
            resolve: function (host, type) {
                var map = { A: 1, AAAA: 28, MX: 15, TXT: 16, SRV: 33, CNAME: 5, NS: 2, PTR: 12, SOA: 6 };
                var t = String(type || 'A').toUpperCase();
                if (!map[t]) return Promise.reject(new Error('unsupported record type ' + t));
                // Node returns every record of the type, not one address from
                // getaddrinfo; lookup() would silently truncate.
                if (t === 'A' || t === 'AAAA')
                    return t === 'A' ? dnsModule.promises.resolve4(host) : dnsModule.promises.resolve6(host);
                return dnsPromise(host, map[t]);
            }
        }
    };

