    // ---- module -------------------------------------------------------
    var BUILTIN_MODULES = [
        'assert', 'assert/strict', 'buffer', 'child_process', 'crypto', 'dgram', 'dns',
        'dns/promises', 'events', 'fs', 'fs/promises', 'http', 'http2', 'https', 'module', 'net', 'os',
        'path', 'path/posix', 'path/win32', 'perf_hooks', 'process', 'querystring', 'readline', 'stream',
        'stream/promises', 'stream/web', 'string_decoder', 'timers', 'timers/promises',
        'tls', 'tty', 'url', 'util', 'util/types', 'v8', 'vm', 'worker_threads', 'zlib',
        'async_hooks', 'sqlite', 'console'
    ];
    function moduleIsBuiltin(name) {
        if (typeof name !== 'string') return false;
        var bare = name.indexOf('node:') === 0 ? name.slice(5) : name;
        return BUILTIN_MODULES.indexOf(bare) !== -1;
    }
    function moduleFileURLToPath(value) {
        var s = String(value);
        if (s.indexOf('file://') !== 0) return s;
        var rest = s.slice(7);
        if (rest.indexOf('localhost/') === 0) rest = rest.slice(9);
        try { return decodeURIComponent(rest); } catch (e) { return rest; }
    }
    function moduleCreateRequire(filename) {
        var dir = pathModule.dirname(moduleFileURLToPath(filename));
        function localRequire(spec) { return __djs.requireFrom(dir, String(spec)); }
        localRequire.resolve = function (spec) { return __djs.resolveFrom(dir, String(spec)); };
        return localRequire;
    }
    function Module(id, parent) {
        this.id = id;
        this.filename = id;
        this.path = id ? pathModule.dirname(id) : null;
        this.exports = {};
        this.loaded = false;
        this.children = [];
        this.parent = parent || null;
    }
    Module.builtinModules = BUILTIN_MODULES.slice();
    Module.isBuiltin = moduleIsBuiltin;
    Module.createRequire = moduleCreateRequire;
    Module.syncBuiltinESMExports = function () {};
    Module.Module = Module;
    var nodeModuleObject = Module;

    // ---- stream/promises ---------------------------------------------
    var streamPromisesModule = {
        pipeline: function () {
            var args = Array.prototype.slice.call(arguments);
            return new Promise(function (resolve, reject) {
                args.push(function (err) { if (err) reject(err); else resolve(); });
                streamModule.pipeline.apply(streamModule, args);
            });
        },
        finished: function (stream) {
            return new Promise(function (resolve, reject) {
                streamModule.finished(stream, function (err) { if (err) reject(err); else resolve(); });
            });
        }
    };

    g.assert = assert;
    g.assert_strict = assertStrict;
    g.nodeModule = nodeModuleObject;
    g.stream_promises = streamPromisesModule;

    g.querystring = {
        escape: function (v) { return encodeURIComponent(String(v)); },
        unescape: function (v) {
            try { return decodeURIComponent(String(v)); } catch (e) { return String(v); }
        },
        parse: function (str, sep, eq) {
            sep = sep || '&'; eq = eq || '=';
            var out = Object.create(null);
            if (typeof str !== 'string' || !str.length) return out;
            var parts = str.split(sep);
            for (var i = 0; i < parts.length; i++) {
                var part = parts[i];
                if (!part) continue;
                var idx = part.indexOf(eq);
                var k = idx < 0 ? part : part.slice(0, idx);
                var v = idx < 0 ? '' : part.slice(idx + eq.length);
                k = this.unescape(k.replace(/\+/g, ' '));
                v = this.unescape(v.replace(/\+/g, ' '));
                if (out[k] === undefined) out[k] = v;
                else if (Array.isArray(out[k])) out[k].push(v);
                else out[k] = [out[k], v];
            }
            return out;
        },
        stringify: function (obj, sep, eq) {
            sep = sep || '&'; eq = eq || '=';
            var parts = [];
            for (var k in obj) {
                if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
                var v = obj[k];
                if (v === undefined) continue;
                var vals = Array.isArray(v) ? v : [v];
                for (var i = 0; i < vals.length; i++)
                    parts.push(this.escape(k) + eq + this.escape(vals[i]));
            }
            return parts.join(sep);
        }
    };
    g.tty = {
        isatty: function (fd) { return __djs.stdio.isTTY(Number(fd)); },
        isTTY: false
    };
    g.dgram = {
        createSocket: function (type, cb) {
            var s = new DgramSocket({ type: type });
            if (cb) queueMicrotask(function () { cb(); });
            return s;
        }
    };
    g.worker_threads = {
        isMainThread: true,
        threadId: 0,
        markAsUncloneable: function (value) { return value; },
        markAsUntransferable: function (value) { return value; },
        MessagePort: MessagePort,
        MessageChannel: MessageChannel,
        Worker: function () {
            var e = new Error('worker_threads is not implemented; the runtime is single-threaded by design');
            e.code = 'ERR_WORKER_THREADS_UNSUPPORTED';
            throw e;
        }
    };

    function httpsRequest(input, options, cb) {
        // Node's https module implies the https: scheme for an options object.
        // http.normalizeHttpOptions defaults to http:, so set it before the
        // shared client sees the request (this also selects the TLS agent).
        if (input && typeof input === 'object' && !(typeof URL === 'function' && input instanceof URL) && !input.protocol) {
            var copy = {};
            for (var k in input) copy[k] = input[k];
            copy.protocol = 'https:';
            if (!copy.port) copy.port = 443;
            return request(copy, options, cb);
        }
        return request(input, options, cb);
    }
    var httpsModule = {
        request: function (input, options, cb) {
            return httpsRequest(input, options, cb);
        },
        get: function (input, options, cb) {
            var req = httpsRequest(input, options, cb);
            req.end();
            return req;
        },
        createServer: function () {
            var e = new Error('TLS server is not implemented; https.createServer is unavailable');
            e.code = 'ERR_TLS_SERVER_UNSUPPORTED';
            throw e;
        }
    };

    function FetchHeaders(obj) {
        this._map = {};
        if (!obj) return;
        if (obj instanceof FetchHeaders) {
            for (var hk in obj._map) this._map[hk] = obj._map[hk];
            return;
        }
        if (typeof obj.forEach === "function" && !Array.isArray(obj)) {
            var self = this;
            obj.forEach(function (v, k) { self._map[String(k).toLowerCase()] = String(v); });
            return;
        }
        for (var k in obj) this._map[String(k).toLowerCase()] = String(obj[k]);
    }
    FetchHeaders.prototype.get = function (k) { var v = this._map[String(k).toLowerCase()]; return v === undefined ? null : v; };
    FetchHeaders.prototype.has = function (k) { return this._map[String(k).toLowerCase()] !== undefined; };
    FetchHeaders.prototype.set = function (k, v) { this._map[String(k).toLowerCase()] = String(v); };
    FetchHeaders.prototype.append = function (k, v) {
        var key = String(k).toLowerCase();
        this._map[key] = this._map[key] === undefined ? String(v) : this._map[key] + ", " + String(v);
    };
    FetchHeaders.prototype.delete = function (k) { delete this._map[String(k).toLowerCase()]; };
    FetchHeaders.prototype.keys = function () { var m = this._map; return Object.keys(m)[Symbol.iterator](); };
    FetchHeaders.prototype.values = function () { var m = this._map; return Object.keys(m).map(function (k) { return m[k]; })[Symbol.iterator](); };
    FetchHeaders.prototype.entries = function () { var m = this._map; return Object.keys(m).map(function (k) { return [k, m[k]]; })[Symbol.iterator](); };
    FetchHeaders.prototype[Symbol.iterator] = function () { return this.entries(); };
    FetchHeaders.prototype.forEach = function (fn) { for (var k in this._map) fn(this._map[k], k, this); };

    function Response(body, init) {
        init = init || {};
        this.status = init.status || 200;
        this.statusText = init.statusText || '';
        this.ok = this.status >= 200 && this.status < 300;
        this.url = init.url || '';
        this.headers = new FetchHeaders(init.headers || {});
        this.bodyUsed = false;
        if (body && typeof body.getReader === "function") {
            this.body = body;
            this._body = null;
        } else {
            this.body = null;
            this._body = body === undefined || body === null ? Buffer.alloc(0) : body;
        }
    }
    function decodeContent(buf, encoding) {
        if (!encoding || !buf || !buf.length) return buf;
        var enc = String(encoding).toLowerCase().trim();
        if (enc === 'gzip' || enc === 'x-gzip') return zlibModule.gunzipSync(buf);
        if (enc === 'deflate') return zlibModule.inflateSync(buf);
        if (enc === 'br') return zlibModule.brotliDecompressSync(buf);
        return buf;
    }

    Response.prototype._consume = function () {
        var self = this;
        if (this.bodyUsed) return Promise.reject(new Error("body already used"));
        this.bodyUsed = true;
        if (!this.body || this._body !== null) {
            var raw = this._body === null ? Buffer.alloc(0) : this._body;
            return Promise.resolve(decodeContent(raw, this._contentEncoding));
        }
        var reader = this.body.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function (r) {
                if (r.done) {
                    var buf = decodeContent(Buffer.concat(chunks), self._contentEncoding);
                    self._body = buf;
                    return buf;
                }
                chunks.push(Buffer.isBuffer(r.value) ? r.value : Buffer.from(r.value));
                return pump();
            });
        }
        return pump();
    };
    Response.prototype.text = function () {
        return this._consume().then(function (b) { return b.toString('utf8'); });
    };
    Response.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };
    Response.prototype.arrayBuffer = function () {
        return this._consume().then(function (b) {
            return b.buffer ? b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) : b;
        });
    };

    function Blob(parts, options) {
        parts = parts || [];
        options = options || {};
        this.type = options.type ? String(options.type).toLowerCase() : '';
        this._parts = [];
        var size = 0;
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i];
            var buf = p instanceof Blob ? p._buffer() : (Buffer.isBuffer(p) ? p : Buffer.from(String(p)));
            this._parts.push(buf);
            size += buf.length;
        }
        this.size = size;
    }
    Blob.prototype._buffer = function () { return Buffer.concat(this._parts); };
    Blob.prototype.arrayBuffer = function () {
        var b = this._buffer();
        return Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
    };
    Blob.prototype.text = function () { return Promise.resolve(this._buffer().toString('utf8')); };
    Blob.prototype.stream = function () {
        var buf = this._buffer();
        return new ReadableStream({
            start: function (c) { if (buf.length) c.enqueue(buf); c.close(); }
        });
    };
    Blob.prototype.slice = function (start, end, type) {
        var b = this._buffer();
        var s = start === undefined ? 0 : (start < 0 ? Math.max(b.length + start, 0) : start);
        var e = end === undefined ? b.length : (end < 0 ? Math.max(b.length + end, 0) : end);
        if (e > b.length) e = b.length;
        if (s > e) s = e;
        return new Blob([b.slice(s, e)], { type: type === undefined ? this.type : type });
    };
    Blob.prototype.toString = function () { return '[object Blob]'; };

    function File(parts, name, options) {
        Blob.call(this, parts, options);
        this.name = String(name);
        this.lastModified = options && options.lastModified !== undefined ? Number(options.lastModified) : Date.now();
    }
    File.prototype = Object.create(Blob.prototype);
    File.prototype.constructor = File;
    File.prototype.toString = function () { return '[object File]'; };

    function FormData() { this._entries = []; }
    FormData.prototype.append = function (name, value, filename) {
        if (value instanceof Blob) {
            this._entries.push([String(name), value, filename === undefined ? 'blob' : String(filename)]);
        } else {
            this._entries.push([String(name), String(value), undefined]);
        }
    };
    FormData.prototype.get = function (name) {
        for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === String(name)) return this._entries[i][1];
        return null;
    };
    FormData.prototype.getAll = function (name) {
        var out = [];
        for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === String(name)) out.push(this._entries[i][1]);
        return out;
    };
    FormData.prototype.has = function (name) {
        for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === String(name)) return true;
        return false;
    };
    FormData.prototype.set = function (name, value, filename) {
        this.delete(name);
        this.append(name, value, filename);
    };
    FormData.prototype.delete = function (name) {
        this._entries = this._entries.filter(function (e) { return e[0] !== String(name); });
    };
    FormData.prototype.forEach = function (fn, thisArg) {
        for (var i = 0; i < this._entries.length; i++) fn.call(thisArg, this._entries[i][1], this._entries[i][0], this);
    };
    FormData.prototype.entries = function () {
        var e = this._entries.map(function (x) { return [x[0], x[1]]; });
        return e[Symbol.iterator]();
    };
    FormData.prototype.keys = function () { return this._entries.map(function (x) { return x[0]; })[Symbol.iterator](); };
    FormData.prototype.values = function () { return this._entries.map(function (x) { return x[1]; })[Symbol.iterator](); };
    FormData.prototype[Symbol.iterator] = FormData.prototype.entries;

    function Request(input, init) {
        init = init || {};
        var src = input && typeof input === "object" && input.url ? input : null;
        this.url = src ? src.url : String(input);
        this.method = String(init.method || (src && src.method) || "GET").toUpperCase();
        this.headers = init.headers instanceof FetchHeaders ? init.headers
            : new FetchHeaders(init.headers || (src && src.headers) || {});
        this._body = init.body !== undefined ? init.body : (src ? src._body : null);
        this.bodyUsed = false;
        this.credentials = init.credentials || (src && src.credentials) || "same-origin";
        this.redirect = init.redirect || (src && src.redirect) || "follow";
    }
    Request.prototype._text = function () {
        if (this.bodyUsed) return Promise.reject(new TypeError("body already used"));
        this.bodyUsed = true;
        if (this._body === null || this._body === undefined) return Promise.resolve("");
        if (typeof this._body === "string") return Promise.resolve(this._body);
        if (Buffer.isBuffer(this._body)) return Promise.resolve(this._body.toString("utf8"));
        return Promise.resolve(String(this._body));
    };
    Request.prototype.text = function () { return this._text(); };
    Request.prototype.json = function () { return this._text().then(function (t) { return JSON.parse(t); }); };
    Request.prototype.arrayBuffer = function () { return this._text().then(function (t) { return Buffer.from(t); }); };
    Request.prototype.clone = function () {
        return new Request(this.url, { method: this.method, headers: this.headers, body: this._body });
    };

    function encodeFormData(fd) {
        var boundary = '----djsFormBoundary' + Buffer.from(__djs.crypto.randomBytes(8)).toString('hex');
        var chunks = [];
        for (var i = 0; i < fd._entries.length; i++) {
            var entry = fd._entries[i];
            var name = String(entry[0]).replace(/"/g, '%22');
            var value = entry[1];
            var head = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"';
            if (value instanceof Blob) {
                head += '; filename="' + String(entry[2] || 'blob').replace(/"/g, '%22') + '"\r\n';
                if (value.type) head += 'Content-Type: ' + value.type + '\r\n';
                head += '\r\n';
                chunks.push(Buffer.from(head, 'utf8'));
                chunks.push(value._buffer());
                chunks.push(Buffer.from('\r\n', 'utf8'));
            } else {
                head += '\r\n\r\n' + String(value) + '\r\n';
                chunks.push(Buffer.from(head, 'utf8'));
            }
        }
        chunks.push(Buffer.from('--' + boundary + '--\r\n', 'utf8'));
        return { body: Buffer.concat(chunks), contentType: 'multipart/form-data; boundary=' + boundary };
    }

    function fetch(input, init) {
        init = init || {};
        return new Promise(function (resolve, reject) {
            // AbortSignal: an already-aborted signal rejects without any I/O;
            // aborting mid-flight tears the request down.
            var signal = init.signal;
            if (signal) {
                if (signal.aborted) {
                    var ae0 = new Error('The operation was aborted');
                    ae0.name = 'AbortError';
                    reject(ae0);
                    return;
                }
                if (typeof signal.addEventListener !== 'function') signal = null;
            }
            var u = new URL(input);
            if (u.protocol !== 'http:' && u.protocol !== 'https:') {
                var e = new Error('only http:// and https:// are supported');
                e.code = 'ERR_INVALID_PROTOCOL';
                reject(e);
                return;
            }
            var headers = init.headers || {};
            if (headers instanceof FetchHeaders) {
                var hm = {};
                headers.forEach(function (v, k) { hm[k] = v; });
                headers = hm;
            } else {
                headers = new FetchHeaders(headers);
                var copyH = {};
                headers.forEach(function (v, k) { copyH[k] = v; });
                headers = copyH;
            }
            var outBody = init.body;
            if (outBody instanceof FormData) {
                var encoded = encodeFormData(outBody);
                outBody = encoded.body;
                if (!headers['content-type']) headers['content-type'] = encoded.contentType;
            } else if (outBody instanceof Blob) {
                if (!headers['content-type'] && outBody.type) headers['content-type'] = outBody.type;
                outBody = outBody._buffer();
            }
            var aborted = false;
            function abortFetch() {
                if (aborted) return;
                aborted = true;
                var ae = new Error('The operation was aborted');
                ae.name = 'AbortError';
                try { req.destroy(); } catch (derr) { /* already gone */ }
                reject(ae);
            }
            if (signal) signal.addEventListener('abort', abortFetch);
            var req = request({ protocol: u.protocol, hostname: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80), path: u.pathname + (u.search || ''), method: init.method || 'GET', headers: headers, rejectUnauthorized: init.rejectUnauthorized !== false }, {}, function (res) {
                if (aborted) return;
                var h = {};
                for (var k in res.headers) if (Object.prototype.hasOwnProperty.call(res.headers, k)) h[k] = res.headers[k];
                var body = null;
                if (typeof ReadableStream === 'function') {
                    body = new ReadableStream({
                        start: function (c) {
                            res.on('data', function (d) { c.enqueue(Buffer.from(d)); });
                            res.on('end', function () { c.close(); });
                            res.on('error', function (e) { c.error(e); });
                        },
                        cancel: function () { req.destroy(); }
                    });
                } else {
                    var chunks = [];
                    body = { _buffered: true };
                    res.on('data', function (c) { chunks.push(c); });
                    res.on('end', function () { body._data = Buffer.concat(chunks); });
                }
                var response = new Response(body, { status: res.statusCode, statusText: res.statusMessage, headers: h, url: u.href });
                response._contentEncoding = h['content-encoding'];
                resolve(response);
            });
            req.on('error', function (err) {
                if (aborted) return;
                reject(err);
            });
            if (outBody !== undefined && outBody !== null) req.write(outBody);
            req.end();
        });
    }

    // ---- crypto / zlib ------------------------------------------------
    function toBytes(data, enc) {
        if (typeof data === 'string') return Buffer.from(data, enc);
        if (Buffer.isBuffer(data)) return data;
        if (data instanceof ArrayBuffer || ArrayBuffer.isView(data))
            return new Buffer(data.buffer ? data.buffer : data, data.byteOffset || 0, data.byteLength);
        throw new TypeError('data must be a string, Buffer, TypedArray or DataView');
    }

    function hashObject(id) {
        this._id = id;
    }
    hashObject.prototype.update = function (data, enc) {
        if (!this._id) throw new Error('digest already called');
        __djs.crypto.update(this._id, toBytes(data, enc));
        return this;
    };
    hashObject.prototype.digest = function (enc) {
        if (!this._id) throw new Error('digest already called');
        var id = this._id;
        this._id = 0;
        var b = Buffer.from(__djs.crypto.digest(id));
        return enc ? b.toString(enc) : b;
    };

    var cryptoModule = {
        createHash: function (algorithm) {
            return new hashObject(__djs.crypto.createHash(String(algorithm).toLowerCase()));
        },
        createHmac: function (algorithm, key) {
            var keyBytes = (key && key.type === 'secret' && key._secret) ? key._secret : toBytes(key);
            return new hashObject(__djs.crypto.createHmac(String(algorithm).toLowerCase(), keyBytes));
        },
        randomBytes: function (size) {
            if (!Number.isInteger(size) || size < 0) throw new TypeError('size must be a non-negative integer');
            return Buffer.from(__djs.crypto.randomBytes(size | 0));
        },
        getRandomValues: function (arr) {
            if (!arr || !ArrayBuffer.isView(arr)) throw new TypeError('expected a TypedArray');
            if (arr.length > 65536) throw new RangeError('getRandomValues exceeds 65536 bytes');
            var bytes = Buffer.from(__djs.crypto.randomBytes(arr.byteLength | 0));
            var view = new Uint8Array(arr.buffer, arr.byteOffset || 0, arr.byteLength);
            for (var i = 0; i < view.length; i++) view[i] = bytes[i];
            return arr;
        },
        randomFillSync: function (buf, offset, size) {
            if (!Buffer.isBuffer(buf) && !ArrayBuffer.isView(buf)) throw new TypeError('buffer must be a Buffer or TypedArray');
            offset = offset === undefined ? 0 : Number(offset);
            size = size === undefined ? buf.length - offset : Number(size);
            var r = Buffer.from(__djs.crypto.randomBytes(size | 0));
            for (var i = 0; i < size; i++) buf[offset + i] = r[i];
            return buf;
        },
        randomFill: function (buf, offset, size, cb) {
            if (typeof offset === 'function') { cb = offset; offset = 0; size = buf.length; }
            else if (typeof size === 'function') { cb = size; size = buf.length - offset; }
            try { this.randomFillSync(buf, offset, size); queueMicrotask(function () { cb(null, buf); }); }
            catch (e) { queueMicrotask(function () { cb(e); }); }
        },
        timingSafeEqual: function (a, b) {
            return __djs.crypto.timingSafeEqual(toBytes(a), toBytes(b));
        },
        createCipheriv: function (algorithm, key, iv) { return new Cipher(algorithm, key, iv, false); },
        createDecipheriv: function (algorithm, key, iv) { return new Cipher(algorithm, key, iv, true); },
        pbkdf2Sync: function (password, salt, iterations, keylen, digest) {
            return Buffer.from(__djs.crypto.pbkdf2(toBytes(password), toBytes(salt),
                Number(iterations), Number(keylen), String(digest || "sha256")));
        },
        hkdfSync: function (digest, ikm, salt, info, keylen) {
            return Buffer.from(__djs.crypto.hkdf(String(digest), toBytes(ikm),
                toBytes(salt || Buffer.alloc(0)), toBytes(info || Buffer.alloc(0)), Number(keylen)));
        },
        scryptSync: function (password, salt, keylen, options) {
            options = options || {};
            return Buffer.from(__djs.crypto.scrypt(toBytes(password), toBytes(salt), Number(keylen),
                Number(options.N || 16384), Number(options.r || 8), Number(options.p || 1)));
        },
        pbkdf2: function (password, salt, iterations, keylen, digest, cb) {
            if (typeof digest === 'function') { cb = digest; digest = 'sha256'; }
            var f = cryptoModule.pbkdf2Sync;
            queueMicrotask(function () { try { cb(null, f(password, salt, iterations, keylen, digest)); } catch (e) { cb(e); } });
        },
        sign: function (algorithm, data, key, cb) {
            var out = Buffer.from(__djs.crypto.sign(normalizeCryptoAlg(algorithm), toBytes(data), keyMaterial(key)));
            if (typeof cb === 'function') { queueMicrotask(function () { cb(null, out); }); return undefined; }
            return out;
        },
        verify: function (algorithm, data, key, signature, cb) {
            if (typeof signature === 'function') { cb = signature; signature = key; }
            var out = __djs.crypto.verify(normalizeCryptoAlg(algorithm), toBytes(data),
                keyMaterial(key), toBytes(signature));
            if (typeof cb === 'function') { queueMicrotask(function () { cb(null, out); }); return undefined; }
            return out;
        },
        createPrivateKey: function (key) { return new KeyObject('private', keyMaterial(key, 'PRIVATE KEY')); },
        createSecretKey: function (key) { return new KeyObject('secret', null, toBytes(key)); },
        KeyObject: KeyObject,
        createSign: function (algorithm) { return new SignStream(algorithm); },
        createVerify: function (algorithm) { return new VerifyStream(algorithm); },
        hkdf: function (digest, ikm, salt, info, keylen, cb) {
            var f = cryptoModule.hkdfSync;
            queueMicrotask(function () { try { cb(null, f(digest, ikm, salt, info, keylen)); } catch (e) { cb(e); } });
        },
        generateKeyPairSync: function (type, options) {
            options = options || {};
            var curve = options.namedCurve || 'prime256v1';
            var bits = Number(options.modulusLength || 2048);
            var out = __djs.crypto.generateKeyPair(String(type).toLowerCase(), bits, String(curve));
            return {
                publicKey: new KeyObject('public', out.publicKey),
                privateKey: new KeyObject('private', out.privateKey)
            };
        },
        generateKeyPair: function (type, options, cb) {
            if (typeof options === 'function') { cb = options; options = {}; }
            queueMicrotask(function () {
                try { cb(null, cryptoModule.generateKeyPairSync(type, options)); }
                catch (e) { cb(e); }
            });
        },
        X509Certificate: X509Certificate,
        createPublicKey: function (key) { return new KeyObject('public', keyMaterial(key, 'PUBLIC KEY')); },
        scrypt: function (password, salt, keylen, options, cb) {
            if (typeof options === 'function') { cb = options; options = {}; }
            var f = cryptoModule.scryptSync;
            queueMicrotask(function () { try { cb(null, f(password, salt, keylen, options)); } catch (e) { cb(e); } });
        },
        randomUUID: function () {
            var b = Buffer.from(__djs.crypto.randomBytes(16));
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            var h = b.toString('hex');
            return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' +
                   h.slice(16, 20) + '-' + h.slice(20);
        }
    };

    function keyTypeFromPem(pem) {
        if (!pem) return undefined;
        var label = /-----BEGIN ([^-]+)-----/.exec(String(pem));
        if (label && label[1].indexOf('RSA') !== -1) return 'rsa';
        if (label && label[1].indexOf('EC') !== -1) return 'ec';
        try {
            var der = typeof pem === 'string'
                ? Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64')
                : Buffer.from(pem);
            if (der.indexOf(Buffer.from([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])) !== -1) return 'rsa';
            if (der.indexOf(Buffer.from([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])) !== -1) return 'ec';
            if (der.indexOf(Buffer.from([0x2B, 0x65, 0x70])) !== -1) return 'ed25519';
        } catch (e) { /* ignore */ }
        return undefined;
    }

    function derElement(buf, off) {
        var tag = buf[off], len = buf[off + 1], p = off + 2;
        if (len & 0x80) {
            var n = len & 0x7F, v = 0;
            for (var i = 0; i < n; i++) v = (v << 8) | buf[p + i];
            p += n; len = v;
        }
        return { tag: tag, start: p, end: p + len, next: p + len };
    }
    function rsaModulusBits(pem) {
        try {
            var der = typeof pem === 'string'
                ? Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64')
                : Buffer.from(pem);
            var outer = derElement(der, 0);
            var body = outer, publicKey = false;
            if (/PUBLIC KEY/.test(String(pem).slice(0, 40))) {
                publicKey = true;
                var alg = derElement(der, outer.start);
                var bits = derElement(der, alg.next);
                body = derElement(der, bits.start + 1);
            } else if (!/RSA PRIVATE KEY/.test(String(pem).slice(0, 40))) {
                var version = derElement(der, outer.start);
                var alg2 = derElement(der, version.next);
                var octet = derElement(der, alg2.next);
                body = derElement(der, octet.start);
            }
            var mod;
            if (publicKey) mod = derElement(der, body.start);
            else {
                var ver = derElement(der, body.start);
                mod = derElement(der, ver.next);
            }
            var bytes = mod.end - mod.start;
            if (der[mod.start] === 0) bytes--;
            return bytes * 8;
        } catch (e) { return undefined; }
    }

    function KeyObject(type, pem, secret) {
        this.type = type;
        this._pem = pem || null;
        this._secret = secret || null;
        this.asymmetricKeyType = type === 'secret' ? undefined : keyTypeFromPem(pem);
        this.asymmetricKeyDetails = {};
        if (this.asymmetricKeyType === 'rsa') {
            var bits = rsaModulusBits(pem);
            if (bits) this.asymmetricKeyDetails.modulusLength = bits;
        }
    }
    KeyObject.prototype.export = function (options) {
        options = options || {};
        if (this.type === 'secret') return Buffer.from(this._secret);
        if (!this._pem) return undefined;
        if (options.format === 'der') {
            var body = String(this._pem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
            return Buffer.from(body, 'base64');
        }
        return this._pem;
    };
    KeyObject.prototype.toString = function () { return this.type === 'secret' ? '[object KeyObject]' : String(this._pem); };
    KeyObject.from = function (key) {
        if (key instanceof KeyObject) return key;
        if (key instanceof CryptoKey) {
            if (key.type === 'secret') return new KeyObject('secret', null, key._secret);
            return new KeyObject(key.type, key._pem, null);
        }
        throw new TypeError('KeyObject.from expects a CryptoKey or KeyObject');
    };

    function SignStream(algorithm) { this._algorithm = algorithm; this._chunks = []; }
    SignStream.prototype.update = function (data, encoding) {
        this._chunks.push(Buffer.isBuffer(data) ? data : Buffer.from(data, encoding || 'utf8'));
        return this;
    };
    SignStream.prototype.sign = function (key, encoding) {
        var sig = cryptoModule.sign(this._algorithm, Buffer.concat(this._chunks), key);
        return encoding ? sig.toString(encoding) : sig;
    };

    function VerifyStream(algorithm) { this._algorithm = algorithm; this._chunks = []; }
    VerifyStream.prototype.update = function (data, encoding) {
        this._chunks.push(Buffer.isBuffer(data) ? data : Buffer.from(data, encoding || 'utf8'));
        return this;
    };
    VerifyStream.prototype.verify = function (key, signature, encoding) {
        var sig = typeof signature === 'string' ? Buffer.from(signature, encoding || 'hex') : signature;
        return cryptoModule.verify(this._algorithm, Buffer.concat(this._chunks), key, sig);
    };

    function X509Certificate(pem) {
        if (pem instanceof X509Certificate) pem = pem._pem;
        this._pem = String(pem);
        var info = __djs.crypto.x509(this._pem);
        this.subject = info.subject || '';
        this.issuer = info.issuer || '';
        this.validFrom = info.validFrom || '';
        this.validTo = info.validTo || '';
        this.validFromDate = new Date(this.validFrom);
        this.validToDate = new Date(this.validTo);
        this.fingerprint256 = info.fingerprint256 || '';
        this.serialNumber = info.serialNumber || '';
    }
    X509Certificate.prototype.checkHost = function (host) {
        return __djs.crypto.x509CheckHost(this._pem, String(host)) ? String(host) : undefined;
    };
    X509Certificate.prototype.toString = function () { return this._pem; };

    function derToPem(der, label) {
        var buf = Buffer.isBuffer(der) ? der : Buffer.from(der);
        var b64 = buf.toString('base64').match(/.{1,64}/g).join('\n');
        return '-----BEGIN ' + label + '-----\n' + b64 + '\n-----END ' + label + '-----\n';
    }
    function keyMaterial(key, label) {
        if (key && typeof key === 'object') {
            if (key._pem !== undefined) return key._pem;
            if (key.key !== undefined) key = key.key;
        }
        if (typeof key === 'string') return key;
        if (Buffer.isBuffer(key) || key instanceof ArrayBuffer || ArrayBuffer.isView(key))
            return derToPem(key, label || 'PRIVATE KEY');
        return key;
    }
    function normalizeCryptoAlg(algorithm) {
        return String(algorithm).toLowerCase().replace(/^(rsa|ec|dsa)-/, '');
    }

    function Cipher(algorithm, key, iv, decrypt) {
        this._alg = String(algorithm);
        this._key = toBytes(key);
        this._iv = toBytes(iv);
        this._decrypt = !!decrypt;
        this._chunks = [];
        this._aad = null;
        this._tag = null;
        this._done = false;
    }
    Cipher.prototype.update = function (data) {
        if (this._done) throw new Error('cipher already finalized');
        this._chunks.push(toBytes(data));
        return Buffer.alloc(0);
    };
    Cipher.prototype.final = function () {
        if (this._done) throw new Error('cipher already finalized');
        this._done = true;
        var input = Buffer.concat(this._chunks);
        var r = __djs.crypto.cipher(this._decrypt ? 1 : 0, this._alg, this._key, this._iv, input, this._aad, this._tag);
        if (!this._decrypt && r.tag) this._tag = Buffer.from(r.tag);
        return Buffer.from(r.data);
    };
    Cipher.prototype.getAuthTag = function () {
        if (!this._tag) throw new Error('auth tag is not available');
        return this._tag;
    };
    Cipher.prototype.setAuthTag = function (tag) { this._tag = toBytes(tag); return this; };
    Cipher.prototype.setAAD = function (aad) { this._aad = toBytes(aad); return this; };
    Cipher.prototype.setAutoPadding = function () { return this; };
    Cipher.prototype.update = Cipher.prototype.update;

    var zlibConstants = {
        Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3,
        Z_FINISH: 4, Z_DEFAULT_COMPRESSION: -1, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9,
        BROTLI_PARAM_QUALITY: 1
    };
    var Z_DEFLATE = 0, Z_INFLATE = 1, Z_GZIP = 2, Z_GUNZIP = 3, Z_RAW_DEFLATE = 4, Z_RAW_INFLATE = 5;

    function zlibLevel(opts) {
        return opts && typeof opts.level === 'number' ? opts.level : -1;
    }
    function zlibSync(data, kind, opts) {
        var id = __djs.zlib.create(kind, zlibLevel(opts));
        var out = [];
        out.push(Buffer.from(__djs.zlib.write(id, toBytes(data))));
        out.push(Buffer.from(__djs.zlib.end(id)));
        return Buffer.concat(out);
    }
    function zlibStream(kind, opts) {
        var id = __djs.zlib.create(kind, zlibLevel(opts));
        var live = true;
        return new Transform({
            transform: function (chunk, enc, cb) {
                if (!live) { cb(new Error('zlib stream closed')); return; }
                try { cb(null, Buffer.from(__djs.zlib.write(id, chunk))); }
                catch (e) { live = false; id = 0; cb(e); }
            },
            final: function (cb) {
                if (!live) { cb(); return; }
                try {
                    var tail = __djs.zlib.end(id);
                    live = false;
                    id = 0;
                    this.push(Buffer.from(tail));
                    this.push(null);
                    cb();
                } catch (e) { live = false; id = 0; cb(e); }
            }
        });
    }

    var zlibModule = {
        constants: zlibConstants,
        deflateSync: function (data, opts) { return zlibSync(data, Z_DEFLATE, opts); },
        inflateSync: function (data, opts) { return zlibSync(data, Z_INFLATE, opts); },
        gzipSync: function (data, opts) { return zlibSync(data, Z_GZIP, opts); },
        gunzipSync: function (data, opts) { return zlibSync(data, Z_GUNZIP, opts); },
        deflateRawSync: function (data, opts) { return zlibSync(data, Z_RAW_DEFLATE, opts); },
        inflateRawSync: function (data, opts) { return zlibSync(data, Z_RAW_INFLATE, opts); },
        createDeflate: function (opts) { return zlibStream(Z_DEFLATE, opts); },
        createInflate: function (opts) { return zlibStream(Z_INFLATE, opts); },
        createGzip: function (opts) { return zlibStream(Z_GZIP, opts); },
        createGunzip: function (opts) { return zlibStream(Z_GUNZIP, opts); },
        createDeflateRaw: function (opts) { return zlibStream(Z_RAW_DEFLATE, opts); },
        createInflateRaw: function (opts) { return zlibStream(Z_RAW_INFLATE, opts); },
        brotliCompressSync: function (data, opts) {
            var q = opts && opts.params && opts.params[zlibConstants.BROTLI_PARAM_QUALITY];
            return Buffer.from(__djs.zlib.brotliCompress(toBytes(data), q === undefined ? 5 : Number(q)));
        },
        brotliDecompressSync: function (data) { return Buffer.from(__djs.zlib.brotliDecompress(toBytes(data))); },
        crc32: (function () {
            var table = null;
            function makeTable() {
                var t = new Array(256);
                for (var n = 0; n < 256; n++) {
                    var c = n;
                    for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
                    t[n] = c >>> 0;
                }
                return t;
            }
            return function (data, value) {
                if (!table) table = makeTable();
                var buf = toBytes(data);
                var crc = ((value === undefined ? 0 : Number(value)) ^ 0xFFFFFFFF) >>> 0;
                for (var i = 0; i < buf.length; i++) crc = (table[(crc ^ buf[i]) & 0xFF] ^ (crc >>> 8)) >>> 0;
                return (crc ^ 0xFFFFFFFF) >>> 0;
            };
        })()
    };

