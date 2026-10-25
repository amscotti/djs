// DJS prelude. Installed into a fresh context before user code runs.
// Native primitives live on __djs; the Node-shaped API is built here.
(function (g) {
    'use strict';

    // CommonJS packages of every vintage reference `global`; Node defines it
    // as an alias for the global object.
    g.global = g;

    var inspectCustom = Symbol.for('nodejs.util.inspect.custom');

    function inspect(value, depth, seen, topLevel) {
        var t = typeof value;
        if (value && typeof value[inspectCustom] === 'function')
            return String(value[inspectCustom](depth, {}));
        if (t === 'string') {
            if (topLevel) return value;
            return "'" + value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")
                .replace(/\n/g, '\\n') + "'";
        }
        if (t === 'number') {
            if (Object.is(value, -0)) return '-0';
            return String(value);
        }
        if (t === 'bigint') return String(value) + 'n';
        if (t === 'boolean' || t === 'undefined') return String(value);
        if (t === 'symbol') return String(value);
        if (t === 'function') return '[Function: ' + (value.name || 'anonymous') + ']';
        if (value === null) return 'null';
        if (value instanceof Timeout) {
            return 'Timeout { id: ' + String(value._id) + ', delay: ' + value._delay +
                ', repeat: ' + value._repeat + ', ref: ' + value.hasRef() + ' }';
        }
        if (value instanceof Error) {
            var head = value.name + (value.message ? ': ' + value.message : '');
            var st = value.stack;
            if (!st) return head;
            return st.indexOf(head) === 0 ? st : head + '\n' + st;
        }
        if (seen.indexOf(value) >= 0) return '[Circular]';
        // Node's util.inspect default depth is 2: the object itself plus two
        // nested levels, then [Object]/[Array].
        if (depth >= 2) return Array.isArray(value) ? '[Array]' : '[Object]';

        seen.push(value);
        var out;
        if (Array.isArray(value)) {
            if (value.length === 0) {
                out = '[]';
            } else {
                var parts = [];
                for (var i = 0; i < value.length; i++)
                    parts.push(inspect(value[i], depth + 1, seen, false));
                out = '[ ' + parts.join(', ') + ' ]';
            }
        } else {
            var keys = Object.keys(value);
            if (keys.length === 0) {
                out = '{}';
            } else {
                var fields = [];
                for (var k = 0; k < keys.length; k++) {
                    var v;
                    try { v = value[keys[k]]; } catch (e) { v = '[Getter]'; }
                    fields.push(keys[k] + ': ' + inspect(v, depth + 1, seen, false));
                }
                out = '{ ' + fields.join(', ') + ' }';
            }
        }
        seen.pop();
        return out;
    }

    function format(fmt, args) {
        if (typeof fmt !== 'string') {
            var all = [inspect(fmt, 0, [], true)];
            for (var n = 0; n < args.length; n++)
                all.push(inspect(args[n], 0, [], true));
            return all.join(' ');
        }
        var out = '';
        var ai = 0;
        for (var i = 0; i < fmt.length; i++) {
            if (fmt.charCodeAt(i) === 37 /* % */ && i + 1 < fmt.length) {
                var c = fmt[i + 1];
                if (c === '%') { out += '%'; i++; continue; }
                if (ai < args.length && 'sdifjoO'.indexOf(c) >= 0) {
                    var a = args[ai++];
                    if (c === 's') out += (typeof a === 'string') ? a : inspect(a, 0, [], true);
                    else if (c === 'd') out += String(Number(a));
                    else if (c === 'f') out += String(Number(a));
                    else if (c === 'i') out += String(parseInt(a, 10));
                    else if (c === 'j') {
                        try { out += JSON.stringify(a); }
                        catch (e) { out += '[Circular]'; }
                    } else out += inspect(a, 0, [], true);
                    i++;
                    continue;
                }
            }
            out += fmt[i];
        }
        while (ai < args.length)
            out += ' ' + inspect(args[ai++], 0, [], true);
        return out;
    }

    function writeLine(fd, text) {
        __djs.console.write(fd, text + '\n');
    }

    var consoleObj = {
        log: function () {
            var args = [];
            for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
            writeLine(1, args.length === 0 ? '' : format(args[0], args.slice(1)));
        },
        info: function () { consoleObj.log.apply(null, arguments); },
        error: function () {
            var args = [];
            for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
            writeLine(2, args.length === 0 ? '' : format(args[0], args.slice(1)));
        },
        warn: function () { consoleObj.error.apply(null, arguments); },
        debug: function () { consoleObj.log.apply(null, arguments); }
    };

    function normalizeDelay(delay) {
        delay = Number(delay);
        if (!(delay >= 1) || delay > 2147483647) {
            if (delay > 2147483647)
                __djs.console.write(2, '(djs) Warning: Timeout duration was set to 1.\n');
            return 1;
        }
        return Math.floor(delay);
    }

    function Timeout(callback, delay, repeat) {
        this._callback = callback;
        this._delay = delay;
        this._repeat = repeat;
        this._id = 0n;
        this._start();
    }

    Timeout.prototype._start = function () {
        var self = this;
        this._id = __djs.timer.start(this._delay, this._repeat, function () {
            if (!self._repeat) self._id = 0n;
            self._callback();
        });
    };

    Timeout.prototype._clear = function () {
        if (this._id !== 0n) {
            __djs.timer.clear(this._id);
            this._id = 0n;
        }
    };

    Timeout.prototype.ref = function () {
        if (this._id !== 0n) __djs.timer.ref(this._id, true);
        return this;
    };

    Timeout.prototype.unref = function () {
        if (this._id !== 0n) __djs.timer.ref(this._id, false);
        return this;
    };

    Timeout.prototype.hasRef = function () {
        return this._id !== 0n ? __djs.timer.hasRef(this._id) : false;
    };

    Timeout.prototype.refresh = function () {
        // Node: refresh() on an inactive timer is a no-op.
        if (this._id !== 0n) __djs.timer.refresh(this._id, this._delay);
        return this;
    };

    Timeout.prototype[Symbol.toPrimitive] = function () { return Number(this._id); };

    function setTimeout(callback, delay) {
        if (typeof callback !== 'function')
            throw new TypeError('The "callback" argument must be of type function');
        var extra = [];
        for (var i = 2; i < arguments.length; i++) extra.push(arguments[i]);
        return new Timeout(function () { callback.apply(undefined, extra); },
                           normalizeDelay(delay), false);
    }

    function setInterval(callback, delay) {
        if (typeof callback !== 'function')
            throw new TypeError('The "callback" argument must be of type function');
        var extra = [];
        for (var i = 2; i < arguments.length; i++) extra.push(arguments[i]);
        return new Timeout(function () { callback.apply(undefined, extra); },
                           normalizeDelay(delay), true);
    }

    function clearTimeout(timer) {
        if (timer === undefined || timer === null) return;
        if (timer instanceof Timeout) { timer._clear(); return; }
        if (typeof timer === 'number' || typeof timer === 'string' ||
            typeof timer === 'bigint') {
            try { __djs.timer.clear(timer); } catch (e) { /* ignore */ }
        }
    }

    var clearImmediate = clearTimeout;

    function setImmediate(callback) {
        if (typeof callback !== 'function')
            throw new TypeError('The "callback" argument must be of type function');
        var extra = [];
        for (var i = 1; i < arguments.length; i++) extra.push(arguments[i]);
        return new Timeout(function () { callback.apply(undefined, extra); }, 1, false);
    }

    function queueMicrotask(callback) {
        if (typeof callback !== 'function')
            throw new TypeError('The "callback" argument must be of type function');
        __djs.queueMicrotask(callback);
    }

    // ---- process -------------------------------------------------------

    var processObj = {
        argv: __djs.process.argv(),
        env: __djs.process.env(),
        cwd: function () { return __djs.process.cwd(); },
        exit: function (code) { __djs.process.exit(code === undefined ? 0 : code); },
        platform: __djs.process.platform(),
        arch: __djs.process.arch(),
        version: __djs.process.version(),
        // The Node API level djs emulates. `process.version` stays djs's own,
        // as in Deno; libraries gate features on `versions.node`, so it must
        // name the newest Node whose surface is implemented.
        versions: {
            node: '22.11.0',
            modules: '127',
            v8: '12.4.254.21',
            uv: __djs.process.uvVersion(),
            openssl: '3.0.13',
            djs: __djs.process.version().replace(/^v/, '')
        },
        release: { name: 'djs', sourceUrl: '', headersUrl: '' },
        features: {
            inspector: false,
            debug: false,
            uv: true,
            ipv6: true,
            tls: true,
            tls_alpn: true,
            tls_sni: true,
            tls_ocsp: false,
            tls_psk: false,
            cached_builtins: true,
            typescript: false
        },
        // djs has no Node CLI flags to forward; child_process.fork uses this
        // list, and an empty one is the honest answer.
        execArgv: [],
        memoryUsage: function () { return __djs.process.memoryUsage(); },
        uptime: function () { return __djs.process.uptime(); },
        cpuUsage: function (prev) {
            var now = __djs.process.cpuUsage();
            if (!prev) return now;
            return { user: now.user - prev.user, system: now.system - prev.system };
        },
        umask: function (mask) { return mask === undefined ? __djs.process.umask() : __djs.process.umask(mask); },
        kill: function (pid, sig) {
            return __djs.process.kill(pid, sig === undefined ? 'SIGTERM' : sig);
        },
        hrtime: (function () {
            function hrtime(prev) {
                var t = __djs.process.hrtime();
                if (!prev) return [t[0], t[1]];
                var s = t[0] - prev[0], n = t[1] - prev[1];
                if (n < 0) { s -= 1; n += 1000000000; }
                return [s, n];
            }
            hrtime.bigint = function () {
                var t = __djs.process.hrtime();
                return BigInt(t[0]) * BigInt(1000000000) + BigInt(t[1]);
            };
            return hrtime;
        })(),
        permission: __djs.process.permission,
        nextTick: function (callback) {
            if (typeof callback !== 'function')
                throw new TypeError('The "callback" argument must be of type function');
            var extra = [];
            for (var i = 1; i < arguments.length; i++) extra.push(arguments[i]);
            __djs.queueMicrotask(function () { callback.apply(undefined, extra); });
        }
    };

    // ---- path ----------------------------------------------------------

    var pathModule = (function () {
        var sep = '/';

        function normalize(p) {
            p = String(p);
            if (p.length === 0) return '.';
            if (p === './') return './';
            var absolute = p.charCodeAt(0) === 47;
            var trailing = p.length > 1 && p.charCodeAt(p.length - 1) === 47;
            var parts = p.split('/');
            var out = [];
            for (var i = 0; i < parts.length; i++) {
                var part = parts[i];
                if (part === '' || part === '.') continue;
                if (part === '..') {
                    if (out.length > 0 && out[out.length - 1] !== '..') out.pop();
                    else if (!absolute) out.push('..');
                } else out.push(part);
            }
            var joined = out.join('/');
            if (absolute) {
                var abs = '/' + joined;
                return trailing && abs !== '/' ? abs + '/' : abs;
            }
            if (joined.length === 0) return '.';
            return trailing ? joined + '/' : joined;
        }

        function join() {
            var parts = [];
            var trailing = false;
            for (var i = 0; i < arguments.length; i++) {
                if (arguments[i] === '') continue;
                var part = String(arguments[i]);
                parts.push(part);
                trailing = part.charCodeAt(part.length - 1) === 47;
            }
            if (parts.length === 0) return '.';
            var out = normalize(parts.join('/'));
            if (trailing && out.charCodeAt(out.length - 1) !== 47) out += '/';
            return out;
        }

        function resolve() {
            var resolved = '';
            var absolute = false;
            for (var i = arguments.length - 1; i >= -1 && !absolute; i--) {
                var p = i >= 0 ? String(arguments[i]) : processObj.cwd();
                if (p.length === 0) continue;
                resolved = resolved.length === 0 ? p : p + '/' + resolved;
                absolute = p.charCodeAt(0) === 47;
            }
            resolved = normalize(resolved);
            if (absolute && resolved.charCodeAt(0) !== 47) resolved = '/' + resolved;
            return resolved;
        }

        function dirname(p) {
            p = String(p);
            if (p.length === 0) return '.';
            var root = p.charCodeAt(0) === 47;
            var end = p.length;
            while (end > 0 && p.charCodeAt(end - 1) === 47) end--;
            var slash = p.lastIndexOf('/', end - 1);
            if (slash < 0) return root ? '/' : '.';
            if (slash === 0) return '/';
            var out = p.slice(0, slash);
            return out.length === 0 ? '.' : out;
        }

        function basename(p, ext) {
            p = String(p);
            var end = p.length;
            while (end > 0 && p.charCodeAt(end - 1) === 47) end--;
            var start = p.lastIndexOf('/', end - 1) + 1;
            var base = p.slice(start, end);
            if (ext && base.length >= ext.length && base.slice(base.length - ext.length) === ext)
                base = base.slice(0, base.length - ext.length);
            return base;
        }

        function extname(p) {
            p = String(p);
            var end = p.length;
            while (end > 0 && p.charCodeAt(end - 1) === 47) end--;
            var start = p.lastIndexOf('/', end - 1) + 1;
            var base = p.slice(start, end);
            if (base === '.' || base === '..') return '';
            var dot = p.lastIndexOf('.', end - 1);
            if (dot <= start) return '';
            return p.slice(dot, end);
        }

        function relative(from, to) {
            var a = resolve(from).split('/').filter(function (x) { return x.length > 0; });
            var b = resolve(to).split('/').filter(function (x) { return x.length > 0; });
            var i = 0;
            while (i < a.length && i < b.length && a[i] === b[i]) i++;
            var up = [];
            for (var j = i; j < a.length; j++) up.push('..');
            var down = b.slice(i);
            var out = up.concat(down).join('/');
            return out.length === 0 ? '' : out;
        }

        function isAbsolute(p) {
            return String(p).charCodeAt(0) === 47;
        }

        function parse(p) {
            p = String(p);
            var root = p.charCodeAt(0) === 47 ? '/' : '';
            var base = basename(p);
            var ext = extname(p);
            var dir = dirname(p);
            if (dir === '.' && !root) dir = '';
            return {
                root: root,
                dir: dir,
                base: base,
                ext: ext,
                name: ext ? base.slice(0, base.length - ext.length) : base
            };
        }

        function format(obj) {
            var dir = obj.dir || obj.root || '';
            var base = obj.base || ((obj.name || '') + (obj.ext || ''));
            if (!dir) return base;
            return dir === '/' ? '/' + base : dir + '/' + base;
        }

        var mod = {
            sep: sep,
            delimiter: ':',
            join: join,
            resolve: resolve,
            normalize: normalize,
            dirname: dirname,
            basename: basename,
            extname: extname,
            relative: relative,
            isAbsolute: isAbsolute,
            parse: parse,
            format: format
        };
        mod.posix = mod;
        // POSIX has no namespace prefix; Node returns the path unchanged.
        mod.toNamespacedPath = function (p) { return String(p); };

        // Windows-flavoured path API. Implemented for formatting/parsing use
        // (basename/dirname/join/extname on Windows paths), not for filesystem
        // access, which stays POSIX-only on this build.
        var win32 = (function () {
            function isSep(c) { return c === 47 || c === 92; }
            function normalize(p) {
                p = String(p);
                if (p.length === 0) return '.';
                var prefix = '';
                var absolute = false;
                if (p.length >= 2 && p.charCodeAt(1) === 58 && /[A-Za-z]/.test(p.charAt(0))) {
                    prefix = p.slice(0, 2);
                    p = p.slice(2);
                    absolute = true;
                }
                if (p.length && isSep(p.charCodeAt(0))) absolute = true;
                var parts = p.split(/[\\/]+/);
                var out = [];
                for (var i = 0; i < parts.length; i++) {
                    var part = parts[i];
                    if (!part || part === '.') continue;
                    if (part === '..') {
                        if (out.length && out[out.length - 1] !== '..') out.pop();
                        else if (!absolute) out.push('..');
                    } else out.push(part);
                }
                var body = out.join('\\');
                if (prefix) return prefix + (absolute ? '\\' + body : body);
                if (absolute) return '\\' + body;
                return body || '.';
            }
            function join() {
                var parts = [];
                for (var i = 0; i < arguments.length; i++) {
                    if (arguments[i] === '') continue;
                    parts.push(String(arguments[i]));
                }
                if (parts.length === 0) return '.';
                return normalize(parts.join('\\'));
            }
            function resolve() {
                var resolved = '';
                var absolute = false;
                for (var i = arguments.length - 1; i >= -1 && !absolute; i--) {
                    var p = i >= 0 ? String(arguments[i]) : processObj.cwd();
                    if (p.length === 0) continue;
                    resolved = resolved.length === 0 ? p : p + '\\' + resolved;
                    absolute = (p.length >= 2 && p.charCodeAt(1) === 58) || isSep(p.charCodeAt(0));
                }
                var out = normalize(resolved);
                if (out.length >= 2 && out.charCodeAt(1) === 58 && !isSep(out.charCodeAt(2))) {
                    out = out.slice(0, 2) + '\\' + out.slice(2);
                }
                return out;
            }
            function dirname(p) {
                p = String(p).replace(/\/+$/, '');
                var idx = -1;
                for (var i = p.length - 1; i >= 0; i--) if (isSep(p.charCodeAt(i))) { idx = i; break; }
                if (idx < 0) return '.';
                if (idx === 0) return p.charAt(0);
                var head = p.slice(0, idx);
                if (head.length === 2 && head.charCodeAt(1) === 58) return head + '\\';
                return head;
            }
            function basename(p, ext) {
                p = String(p).replace(/\/+$/, '');
                var idx = -1;
                for (var i = p.length - 1; i >= 0; i--) if (isSep(p.charCodeAt(i))) { idx = i; break; }
                var base = p.slice(idx + 1);
                if (ext && base.length >= ext.length && base.slice(base.length - ext.length) === ext)
                    base = base.slice(0, base.length - ext.length);
                return base;
            }
            function extname(p) {
                var base = basename(p);
                var dot = base.lastIndexOf('.');
                if (dot <= 0) return '';
                return base.slice(dot);
            }
            function isAbsolute(p) {
                p = String(p);
                return isSep(p.charCodeAt(0)) || (p.length >= 2 && p.charCodeAt(1) === 58);
            }
            function parse(p) {
                p = String(p);
                var root = '', dir = '', base = '', ext = '';
                if (p.length >= 2 && p.charCodeAt(1) === 58) root = p.slice(0, 2) + '\\';
                var rest = root ? p.slice(2) : p;
                var d = dirname(rest);
                base = basename(rest);
                ext = extname(base);
                dir = d === '.' ? (root || '') : (root ? root + d.replace(/^\\+/, '') : d);
                return { root: root, dir: dir, base: base, ext: ext, name: ext ? base.slice(0, base.length - ext.length) : base };
            }
            function format(obj) {
                var dir = obj.dir || obj.root || '';
                var base = obj.base || ((obj.name || '') + (obj.ext || ''));
                if (!dir) return base;
                return isSep(dir.charCodeAt(dir.length - 1)) ? dir + base : dir + '\\' + base;
            }
            var m = {
                sep: '\\', delimiter: ';', join: join, resolve: resolve, normalize: normalize,
                dirname: dirname, basename: basename, extname: extname, isAbsolute: isAbsolute,
                parse: parse, format: format,
                toNamespacedPath: function (p) { return String(p); }
            };
            m.win32 = m;
            return m;
        })();
        mod.win32 = win32;
        return mod;
    })();

    // ---- V8-style stack introspection ---------------------------------
    // Node packages (depd, express, debug) use Error.captureStackTrace with
    // Error.prepareStackTrace and expect CallSite objects, not a string.
    function parseCallSite(line) {
        var m = /^\s*at\s+(?:(.*?)\s+\()?(.*?):(\d+):(\d+)\)?\s*$/.exec(line);
        var name = null, file = null, lineNo = 0, col = 0;
        if (m) {
            name = m[1] || null;
            file = m[2];
            lineNo = Number(m[3]);
            col = Number(m[4]);
        } else {
            var n = /^\s*at\s+(.*?)\s*$/.exec(line);
            name = n ? n[1] : null;
            file = name;
        }
        var evalLike = /(^|[\\/])eval|^<eval>$/.test(file || '');
        var site = {
            getFileName: function () { return file; },
            getLineNumber: function () { return lineNo; },
            getColumnNumber: function () { return col; },
            getFunctionName: function () { return name; },
            getMethodName: function () { return name; },
            getTypeName: function () { return null; },
            isEval: function () { return evalLike; },
            getEvalOrigin: function () { return evalLike ? file : undefined; },
            isNative: function () { return !file || file === 'native'; },
            isConstructor: function () { return false; },
            isToplevel: function () { return name === null; },
            toString: function () {
                return name ? name + ' (' + file + ':' + lineNo + ':' + col + ')' : file;
            }
        };
        return site;
    }
    Error.captureStackTrace = function (obj, ctor) {
        // QuickJS honours Error.prepareStackTrace when .stack is read, which
        // would hand us CallSite objects instead of the raw text we parse.
        var saved = Error.prepareStackTrace;
        Error.prepareStackTrace = undefined;
        var raw = (new Error()).stack || '';
        Error.prepareStackTrace = saved;
        if (typeof raw !== 'string') raw = '';
        var lines = String(raw).split('\n');
        if (lines.length && !/^\s*at\s/.test(lines[0])) lines = lines.slice(1);
        var sites = [];
        for (var i = 0; i < lines.length; i++) {
            if (/^\s*at\s/.test(lines[i])) sites.push(parseCallSite(lines[i]));
        }
        if (ctor && ctor.name) {
            for (var j = 0; j < sites.length; j++) {
                if (sites[j].getFunctionName() === ctor.name) {
                    sites = sites.slice(j + 1);
                    break;
                }
            }
        }
        var value = typeof Error.prepareStackTrace === 'function'
            ? Error.prepareStackTrace(obj, sites)
            : raw;
        // QuickJS defines Error.prototype.stack as a string accessor; an own
        // data property is needed for the V8 contract (an array of sites).
        try {
            Object.defineProperty(obj, 'stack', {
                value: value, writable: true, configurable: true, enumerable: false
            });
        } catch (e) { obj.stack = String(value); }
    };
    Error.stackTraceLimit = 10;

    // ---- Buffer -------------------------------------------------------

    function normEncoding(encoding) {
        var e = String(encoding === undefined ? 'utf8' : encoding).toLowerCase();
        if (e === 'binary') return 'latin1';
        return e;
    }


    function bufferCheckOffset(buf, offset, size) {
        offset = Number(offset) || 0;
        if (offset < 0 || offset + size > buf.length) {
            var err = new RangeError('The value of "offset" is out of range. It must be >= 0 and <= ' +
                (buf.length - size) + '. Received ' + offset);
            err.code = 'ERR_OUT_OF_RANGE';
            throw err;
        }
        return offset;
    }
    function bufferCheckBytes(byteLength) {
        byteLength = Number(byteLength) || 0;
        if (byteLength < 1 || byteLength > 6) {
            var err2 = new RangeError('The value of "byteLength" is out of range. It must be >= 1 and <= 6. Received ' + byteLength);
            err2.code = 'ERR_OUT_OF_RANGE';
            throw err2;
        }
        return byteLength;
    }
    function bufferView(buf, offset, size) {
        return new DataView(buf.buffer, buf.byteOffset + offset, size);
    }
    function bufferFind(haystack, needle, from, backwards) {
        if (needle.length === 0) return Math.min(Math.max(from, 0), haystack.length);
        if (backwards) {
            for (var i = Math.min(from, haystack.length - needle.length); i >= 0; i--) {
                var ok = true;
                for (var j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) { ok = false; break; }
                if (ok) return i;
            }
            return -1;
        }
        for (var k = Math.max(from, 0); k <= haystack.length - needle.length; k++) {
            var hit = true;
            for (var m = 0; m < needle.length; m++) if (haystack[k + m] !== needle[m]) { hit = false; break; }
            if (hit) return k;
        }
        return -1;
    }
    function bufferNeedle(value, encoding) {
        if (typeof value === 'number') {
            if (!Number.isInteger(value) || value < 0 || value > 255)
                throw new RangeError('The value of "value" is out of range. It must be >= 0 and <= 255. Received ' + value);
            return new Buffer([value]);
        }
        if (typeof value === 'string') return Buffer.from(value, encoding || 'utf8');
        if (value instanceof Uint8Array) return value;
        throw new TypeError('The "value" argument must be of type string, number, Buffer or Uint8Array');
    }

    class Buffer extends Uint8Array {
        constructor(arg, offset, length) {
            if (arg === undefined) super(0);
            else if (typeof arg === 'number') super(arg);
            else super(arg, offset, length);
        }

        static from(value, encoding) {
            if (typeof value === 'string') {
                var enc = normEncoding(encoding);
                if (enc === 'base64url') {
                    var b64 = value.replace(/-/g, '+').replace(/_/g, '/');
                    while (b64.length % 4) b64 += '=';
                    return new Buffer(__djs.bytes.encode(b64, 'base64'));
                }
                return new Buffer(__djs.bytes.encode(value, enc));
            }
            if (value instanceof ArrayBuffer) return new Buffer(value);
            if (value instanceof Uint8Array) {
                var copy = new Buffer(value.length);
                copy.set(value);
                return copy;
            }
            if (ArrayBuffer.isView(value)) {
                var viewCopy = new Buffer(value.byteLength);
                viewCopy.set(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
                return viewCopy;
            }
            if (Array.isArray(value)) return new Buffer(value);
            throw new TypeError('Buffer.from: unsupported input');
        }

        static alloc(size, fill, encoding) {
            var b = new Buffer(size);
            if (fill === undefined) return b;
            if (typeof fill === 'number') { b.fill(fill); return b; }
            b.fill(fill, 0, size, encoding);
            return b;
        }

        static allocUnsafe(size) { return new Buffer(size); }

        static allocUnsafeSlow(size) { return new Buffer(size); }

        static compare(a, b) {
            var n = Math.min(a.length, b.length);
            for (var i = 0; i < n; i++) {
                if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
            }
            return a.length === b.length ? 0 : (a.length < b.length ? -1 : 1);
        }

        static isBuffer(value) { return value instanceof Buffer; }

        static byteLength(value, encoding) {
            if (typeof value === 'string')
                return __djs.bytes.encode(value, normEncoding(encoding)).byteLength;
            if (value instanceof ArrayBuffer) return value.byteLength;
            if (ArrayBuffer.isView(value)) return value.byteLength;
            throw new TypeError('The "string" argument must be of type string or an instance of Buffer or ArrayBuffer');
        }

        static concat(list, totalLength) {
            var total = totalLength === undefined ? 0 : totalLength;
            if (totalLength === undefined)
                for (var i = 0; i < list.length; i++) total += list[i].length;
            var out = new Buffer(total);
            var off = 0;
            for (var j = 0; j < list.length && off < total; j++) {
                var chunk = list[j];
                var n = Math.min(chunk.length, total - off);
                out.set(chunk.subarray(0, n), off);
                off += n;
            }
            return out;
        }

        toString(encoding, start, end) {
            if (encoding !== null && typeof encoding === 'object') {
                start = encoding.start;
                end = encoding.end;
                encoding = encoding.encoding;
            }
            var s = start === undefined ? 0 : start;
            var e = end === undefined ? this.length : end;
            if (s < 0) s = 0;
            if (e > this.length) e = this.length;
            var enc = normEncoding(encoding);
            if (enc === 'base64url')
                return __djs.bytes.decode(this.subarray(s, e), 'base64')
                    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
            return __djs.bytes.decode(this.subarray(s, e), enc);
        }

        slice(start, end) { return this.subarray(start, end); }

        fill(value, start, end, encoding) {
            var s = start === undefined ? 0 : start;
            var e = end === undefined ? this.length : end;
            if (typeof s === 'string') { encoding = s; s = 0; }
            if (typeof value === 'number')
                return Uint8Array.prototype.fill.call(this, value, s, e);
            var pat = Buffer.from(value, encoding);
            if (pat.length === 0) return this;
            var j = 0;
            for (var i = s; i < e && i < this.length; i++) {
                this[i] = pat[j % pat.length];
                j++;
            }
            return this;
        }

        write(string, offset, length, encoding) {
            if (typeof offset === 'string') { encoding = offset; offset = 0; length = undefined; }
            else if (typeof length === 'string') { encoding = length; length = undefined; }
            var start = offset === undefined ? 0 : offset;
            if (start < 0 || start > this.length)
                throw new RangeError('The value of "offset" is out of range. It must be >= 0 and <= ' + this.length + '. Received ' + start);
            var bytes = Buffer.from(String(string), encoding || 'utf8');
            var max = Math.min(bytes.length, this.length - start);
            if (length !== undefined) max = Math.min(max, length);
            if (max > 0) this.set(bytes.subarray(0, max), start);
            return max;
        }

        equals(other) {
            if (this.length !== other.length) return false;
            for (var i = 0; i < this.length; i++)
                if (this[i] !== other[i]) return false;
            return true;
        }

        compare(other) {
            var n = Math.min(this.length, other.length);
            for (var i = 0; i < n; i++) {
                if (this[i] !== other[i]) return this[i] < other[i] ? -1 : 1;
            }
            if (this.length === other.length) return 0;
            return this.length < other.length ? -1 : 1;
        }

        copy(target, targetStart, sourceStart, sourceEnd) {
            if (!(target instanceof Uint8Array)) throw new TypeError('The "target" argument must be an instance of Buffer or Uint8Array');
            var tStart = targetStart === undefined ? 0 : Number(targetStart);
            var sStart = sourceStart === undefined ? 0 : Number(sourceStart);
            var sEnd = sourceEnd === undefined ? this.length : Number(sourceEnd);
            if (tStart < 0 || tStart > target.length) throw new RangeError('The value of "targetStart" is out of range');
            if (sStart < 0 || sStart > this.length) throw new RangeError('The value of "sourceStart" is out of range');
            if (sEnd > this.length) sEnd = this.length;
            var n = Math.min(sEnd - sStart, target.length - tStart);
            if (n <= 0) return 0;
            target.set(this.subarray(sStart, sStart + n), tStart);
            return n;
        }

        indexOf(value, byteOffset, encoding) {
            if (typeof byteOffset === 'string') { encoding = byteOffset; byteOffset = 0; }
            var from = byteOffset === undefined ? 0 : Number(byteOffset);
            return bufferFind(this, bufferNeedle(value, encoding), from, false);
        }
        lastIndexOf(value, byteOffset, encoding) {
            if (typeof byteOffset === 'string') { encoding = byteOffset; byteOffset = this.length; }
            var from = byteOffset === undefined ? this.length : Number(byteOffset);
            if (from > this.length) from = this.length;
            return bufferFind(this, bufferNeedle(value, encoding), from, true);
        }
        includes(value, byteOffset, encoding) {
            return this.indexOf(value, byteOffset, encoding) !== -1;
        }

        readUInt8(offset) { return this[bufferCheckOffset(this, offset, 1)]; }
        readInt8(offset) { return (this[bufferCheckOffset(this, offset, 1)] << 24) >> 24; }
        readUInt16LE(offset) { offset = bufferCheckOffset(this, offset, 2); return this[offset] | (this[offset + 1] << 8); }
        readUInt16BE(offset) { offset = bufferCheckOffset(this, offset, 2); return (this[offset] << 8) | this[offset + 1]; }
        readInt16LE(offset) { offset = bufferCheckOffset(this, offset, 2); return ((this[offset] | (this[offset + 1] << 8)) << 16) >> 16; }
        readInt16BE(offset) { offset = bufferCheckOffset(this, offset, 2); return (((this[offset] << 8) | this[offset + 1]) << 16) >> 16; }
        readUInt32LE(offset) { offset = bufferCheckOffset(this, offset, 4); return (this[offset] | (this[offset + 1] << 8) | (this[offset + 2] << 16) | (this[offset + 3] << 24)) >>> 0; }
        readUInt32BE(offset) { offset = bufferCheckOffset(this, offset, 4); return ((this[offset] << 24) | (this[offset + 1] << 16) | (this[offset + 2] << 8) | this[offset + 3]) >>> 0; }
        readInt32LE(offset) { offset = bufferCheckOffset(this, offset, 4); return this[offset] | (this[offset + 1] << 8) | (this[offset + 2] << 16) | (this[offset + 3] << 24); }
        readInt32BE(offset) { offset = bufferCheckOffset(this, offset, 4); return (this[offset] << 24) | (this[offset + 1] << 16) | (this[offset + 2] << 8) | this[offset + 3]; }
        readFloatLE(offset) { offset = bufferCheckOffset(this, offset, 4); return bufferView(this, offset, 4).getFloat32(0, true); }
        readFloatBE(offset) { offset = bufferCheckOffset(this, offset, 4); return bufferView(this, offset, 4).getFloat32(0, false); }
        readDoubleLE(offset) { offset = bufferCheckOffset(this, offset, 8); return bufferView(this, offset, 8).getFloat64(0, true); }
        readDoubleBE(offset) { offset = bufferCheckOffset(this, offset, 8); return bufferView(this, offset, 8).getFloat64(0, false); }

        writeUInt8(value, offset) { offset = bufferCheckOffset(this, offset, 1); this[offset] = Number(value) & 0xFF; return offset + 1; }
        writeInt8(value, offset) { offset = bufferCheckOffset(this, offset, 1); this[offset] = Number(value) & 0xFF; return offset + 1; }
        writeUInt16LE(value, offset) { offset = bufferCheckOffset(this, offset, 2); value = Number(value); this[offset] = value & 0xFF; this[offset + 1] = (value >>> 8) & 0xFF; return offset + 2; }
        writeUInt16BE(value, offset) { offset = bufferCheckOffset(this, offset, 2); value = Number(value); this[offset] = (value >>> 8) & 0xFF; this[offset + 1] = value & 0xFF; return offset + 2; }
        writeInt16LE(value, offset) { return this.writeUInt16LE(Number(value) & 0xFFFF, offset); }
        writeInt16BE(value, offset) { return this.writeUInt16BE(Number(value) & 0xFFFF, offset); }
        writeUInt32LE(value, offset) { offset = bufferCheckOffset(this, offset, 4); value = Number(value); for (var i = 0; i < 4; i++) this[offset + i] = (value >>> (i * 8)) & 0xFF; return offset + 4; }
        writeUInt32BE(value, offset) { offset = bufferCheckOffset(this, offset, 4); value = Number(value); for (var i = 0; i < 4; i++) this[offset + i] = (value >>> ((3 - i) * 8)) & 0xFF; return offset + 4; }
        writeInt32LE(value, offset) { return this.writeUInt32LE(Number(value) >>> 0, offset); }
        writeInt32BE(value, offset) { return this.writeUInt32BE(Number(value) >>> 0, offset); }
        writeFloatLE(value, offset) { offset = bufferCheckOffset(this, offset, 4); bufferView(this, offset, 4).setFloat32(0, Number(value), true); return offset + 4; }
        writeFloatBE(value, offset) { offset = bufferCheckOffset(this, offset, 4); bufferView(this, offset, 4).setFloat32(0, Number(value), false); return offset + 4; }
        writeDoubleLE(value, offset) { offset = bufferCheckOffset(this, offset, 8); bufferView(this, offset, 8).setFloat64(0, Number(value), true); return offset + 8; }
        writeDoubleBE(value, offset) { offset = bufferCheckOffset(this, offset, 8); bufferView(this, offset, 8).setFloat64(0, Number(value), false); return offset + 8; }

        readUIntLE(offset, byteLength) {
            byteLength = bufferCheckBytes(byteLength);
            offset = bufferCheckOffset(this, offset, byteLength);
            var v = 0, mul = 1;
            for (var i = 0; i < byteLength; i++) { v += this[offset + i] * mul; mul *= 256; }
            return v;
        }
        readUIntBE(offset, byteLength) {
            byteLength = bufferCheckBytes(byteLength);
            offset = bufferCheckOffset(this, offset, byteLength);
            var v = 0;
            for (var i = 0; i < byteLength; i++) v = v * 256 + this[offset + i];
            return v;
        }
        readIntLE(offset, byteLength) {
            var u = this.readUIntLE(offset, byteLength);
            var limit = Math.pow(2, byteLength * 8 - 1);
            return u >= limit ? u - limit * 2 : u;
        }
        readIntBE(offset, byteLength) {
            var u = this.readUIntBE(offset, byteLength);
            var limit = Math.pow(2, byteLength * 8 - 1);
            return u >= limit ? u - limit * 2 : u;
        }
        writeUIntLE(value, offset, byteLength) {
            byteLength = bufferCheckBytes(byteLength);
            offset = bufferCheckOffset(this, offset, byteLength);
            value = Number(value);
            for (var i = 0; i < byteLength; i++) { this[offset + i] = value & 0xFF; value = Math.floor(value / 256); }
            return offset + byteLength;
        }
        writeUIntBE(value, offset, byteLength) {
            byteLength = bufferCheckBytes(byteLength);
            offset = bufferCheckOffset(this, offset, byteLength);
            value = Number(value);
            for (var i = byteLength - 1; i >= 0; i--) { this[offset + i] = value & 0xFF; value = Math.floor(value / 256); }
            return offset + byteLength;
        }
        writeIntLE(value, offset, byteLength) {
            var v = Number(value);
            if (v < 0) v += Math.pow(2, byteLength * 8);
            return this.writeUIntLE(v, offset, byteLength);
        }
        writeIntBE(value, offset, byteLength) {
            var v = Number(value);
            if (v < 0) v += Math.pow(2, byteLength * 8);
            return this.writeUIntBE(v, offset, byteLength);
        }

        readBigUInt64LE(offset) { offset = bufferCheckOffset(this, offset, 8); var v = 0n; for (var i = 7; i >= 0; i--) v = (v << 8n) | BigInt(this[offset + i]); return v; }
        readBigUInt64BE(offset) { offset = bufferCheckOffset(this, offset, 8); var v = 0n; for (var i = 0; i < 8; i++) v = (v << 8n) | BigInt(this[offset + i]); return v; }
        readBigInt64LE(offset) { var u = this.readBigUInt64LE(offset); return u >= (1n << 63n) ? u - (1n << 64n) : u; }
        readBigInt64BE(offset) { var u = this.readBigUInt64BE(offset); return u >= (1n << 63n) ? u - (1n << 64n) : u; }
        writeBigUInt64LE(value, offset) { offset = bufferCheckOffset(this, offset, 8); var v = BigInt(value); for (var i = 0; i < 8; i++) { this[offset + i] = Number(v & 0xFFn); v >>= 8n; } return offset + 8; }
        writeBigUInt64BE(value, offset) { offset = bufferCheckOffset(this, offset, 8); var v = BigInt(value); for (var i = 7; i >= 0; i--) { this[offset + i] = Number(v & 0xFFn); v >>= 8n; } return offset + 8; }
        writeBigInt64LE(value, offset) { var v = BigInt(value); if (v < 0n) v += 1n << 64n; return this.writeBigUInt64LE(v, offset); }
        writeBigInt64BE(value, offset) { var v = BigInt(value); if (v < 0n) v += 1n << 64n; return this.writeBigUInt64BE(v, offset); }

        swap16() { if (this.length % 2) throw new RangeError('Buffer size must be a multiple of 16-bits'); for (var i = 0; i < this.length; i += 2) { var t = this[i]; this[i] = this[i + 1]; this[i + 1] = t; } return this; }
        swap32() { if (this.length % 4) throw new RangeError('Buffer size must be a multiple of 32-bits'); for (var i = 0; i < this.length; i += 4) { var t = this[i]; this[i] = this[i + 3]; this[i + 3] = t; t = this[i + 1]; this[i + 1] = this[i + 2]; this[i + 2] = t; } return this; }
        swap64() { if (this.length % 8) throw new RangeError('Buffer size must be a multiple of 64-bits'); for (var i = 0; i < this.length; i += 8) { for (var j = 0; j < 4; j++) { var t = this[i + j]; this[i + j] = this[i + 7 - j]; this[i + 7 - j] = t; } } return this; }

        toJSON() { return { type: 'Buffer', data: Array.prototype.slice.call(this) }; }

        static isEncoding(encoding) {
            return ['utf8', 'utf-8', 'hex', 'base64', 'base64url', 'latin1', 'binary',
                    'ascii', 'ucs2', 'ucs-2', 'utf16le', 'utf-16le'].indexOf(String(encoding).toLowerCase()) !== -1;
        }

        readUintLE(o, n) { return this.readUIntLE(o, n); }
        readUintBE(o, n) { return this.readUIntBE(o, n); }
        writeUintLE(v, o, n) { return this.writeUIntLE(v, o, n); }
        writeUintBE(v, o, n) { return this.writeUIntBE(v, o, n); }
    }

