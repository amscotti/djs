    // ---- stream --------------------------------------------------------

    function Stream(opts) {
        EventEmitter.call(this);
        if (opts && opts.objectMode) this._objectMode = true;
    }
    Stream.prototype = Object.create(EventEmitter.prototype);
    Stream.prototype.constructor = Stream;
    Stream.prototype.pipe = function (dest, opts) {
        var self = this;
        function onData(chunk) { if (!dest.write(chunk)) self.pause(); }
        this.on('data', onData);
        this.on('end', function () { dest.end(); });
        this.on('error', function (e) { dest.emit('error', e); });
        if (dest.on) dest.on('drain', function () { self.resume(); });
        return dest;
    };

    function Readable(opts) {
        Stream.call(this, opts);
        this._buffer = [];
        this._flowing = null;
        this._ended = false;
        this._paused = false;
        this.readable = true;
        this.readableEnded = false;
        this.destroyed = false;
        var stateOwner = this;
        this._readableState = { endEmitted: false, flowing: null, objectMode: !!(opts && opts.objectMode) };
        Object.defineProperty(this._readableState, 'length', {
            get: function () {
                var n = 0;
                for (var i = 0; i < stateOwner._buffer.length; i++) {
                    var c = stateOwner._buffer[i];
                    n += typeof c === 'string' ? c.length : c.length;
                }
                return n;
            }
        });
        if (opts && typeof opts.read === 'function') this._read = opts.read;
        this._started = false;
        var self = this;
        queueMicrotask(function () {
            if (!self._started && typeof self._read === 'function') {
                self._started = true;
                self._read();
            }
        });
    }
    Readable.prototype = Object.create(Stream.prototype);
    Readable.prototype.constructor = Readable;
    Readable.prototype._read = function () {};
    // Node's setEncoding: subsequent data events carry strings, decoded with a
    // StringDecoder so multi-byte characters split across chunks survive.
    Readable.prototype.setEncoding = function (encoding) {
        var enc = String(encoding === undefined ? 'utf8' : encoding).toLowerCase();
        this._encoding = enc;
        this._decoder = (g.string_decoder && g.string_decoder.StringDecoder)
            ? new g.string_decoder.StringDecoder(enc)
            : null;
        return this;
    };
    Readable.prototype.push = function (chunk) {
        if (this.destroyed) return false;
        if (chunk === null) {
            this._ended = true;
            this.readable = false;
            if (this._decoder) {
                var tail = this._decoder.end();
                this._decoder = null;
                if (tail) {
                    if (this._flowing) this.emit('data', tail);
                    else this._buffer.push(tail);
                    return true;
                }
            }
            if (this._buffer.length === 0) this._emitEnd();
            return false;
        }
        if (this._decoder) chunk = this._decoder.write(chunk);
        if (this._flowing) this.emit('data', chunk);
        else this._buffer.push(chunk);
        return this._buffer.length < 16;
    };
    Readable.prototype.unshift = function (chunk) {
        if (chunk !== null) this._buffer.unshift(chunk);
    };
    Readable.prototype._emitEnd = function () {
        if (this.readableEnded) return;
        this.readableEnded = true;
        if (this._readableState) this._readableState.endEmitted = true;
        this.emit('end');
    };
    Readable.prototype.read = function (n) {
        if (this._buffer.length === 0) return null;
        if (n === undefined || n === null) {
            var all = this._buffer.length === 1 ? this._buffer[0] : this._buffer.join('');
            this._buffer = [];
            if (this._ended) queueMicrotask(this._emitEnd.bind(this));
            return all;
        }
        var out = this._buffer.join('').slice(0, n);
        this._buffer = [this._buffer.join('').slice(n)];
        return out.length ? out : null;
    };
    Readable.prototype.pause = function () { this._flowing = false; this._paused = true; return this; };
    Readable.prototype.resume = function () {
        this._paused = false;
        this._flowing = true;
        while (this._buffer.length) this.emit('data', this._buffer.shift());
        if (this._ended) this._emitEnd();
        return this;
    };
    Readable.prototype.on = function (name, fn) {
        var r = Stream.prototype.on.call(this, name, fn);
        var self = this;
        if (name === 'data' && !this._flowing)
            queueMicrotask(function () { if (!self._flowing) self.resume(); });
        return r;
    };
    Readable.prototype.pipe = function (dest, opts) {
        var self = this;
        this.on('data', function (chunk) { if (!dest.write(chunk)) self.pause(); });
        this.on('end', function () { dest.end(); });
        this.on('error', function (e) { if (dest.emit) dest.emit('error', e); });
        if (dest.on) dest.on('drain', function () { self.resume(); });
        if (opts && opts.end === false) { /* caller ends dest */ }
        return dest;
    };
    Readable.prototype.destroy = function (err) {
        this.destroyed = true;
        if (err) this.emit('error', err);
        this.emit('close');
        return this;
    };
    // Async iteration pulls one chunk at a time and pauses between reads.
    // Attaching a fresh 'data' listener per next() lost every chunk produced
    // while the consumer was between awaits, and a producer that pushed data
    // and EOF in the same turn left the next next() waiting for an 'end' that
    // had already fired. This version buffers into a queue, pauses when the
    // queue is not being drained, and rejects (rather than throws from an
    // event handler) when the stream errors.
    Readable.prototype[Symbol.asyncIterator] = function () {
        var self = this;
        var queue = [];
        var ended = false;
        var failure = null;
        var waiter = null;

        if (self.readableEnded || self.destroyed || (self._ended && self._buffer.length === 0))
            ended = true;

        function settle() {
            if (!waiter) {
                if (queue.length) self.pause();
                return;
            }
            if (queue.length) {
                var w = waiter;
                waiter = null;
                w.resolve({ done: false, value: queue.shift() });
                if (!queue.length) self.pause();
                return;
            }
            if (failure) {
                var f = waiter;
                waiter = null;
                f.reject(failure);
                return;
            }
            if (ended) {
                var d = waiter;
                waiter = null;
                d.resolve({ done: true, value: undefined });
            }
        }
        function onData(chunk) { queue.push(chunk); settle(); }
        function onEnd() { ended = true; settle(); }
        function onError(err) { failure = err; settle(); }
        function release() {
            self.removeListener('data', onData);
            self.removeListener('end', onEnd);
            self.removeListener('error', onError);
        }

        self.on('data', onData);
        self.once('end', onEnd);
        self.once('error', onError);

        return {
            next: function () {
                return new Promise(function (resolve, reject) {
                    if (waiter) {
                        reject(new TypeError('The async iterator is already reading'));
                        return;
                    }
                    if (queue.length) {
                        resolve({ done: false, value: queue.shift() });
                        if (!queue.length) self.pause();
                        return;
                    }
                    if (failure) { reject(failure); return; }
                    if (ended) { resolve({ done: true, value: undefined }); return; }
                    waiter = { resolve: resolve, reject: reject };
                    self.resume();
                    settle();
                });
            },
            return: function (value) {
                ended = true;
                queue.length = 0;
                release();
                if (typeof self.destroy === 'function' && !self.destroyed) self.destroy();
                else self.pause();
                return Promise.resolve({ done: true, value: value });
            },
            throw: function (err) {
                ended = true;
                queue.length = 0;
                release();
                if (typeof self.destroy === 'function' && !self.destroyed) self.destroy();
                else self.pause();
                return Promise.reject(err);
            }
        };
    };
    Readable.from = function (iterable) {
        var r = new Readable();
        if (iterable && typeof iterable[Symbol.iterator] === 'function') {
            var arr = Array.from(iterable);
            for (var i = 0; i < arr.length; i++) r.push(arr[i]);
        }
        r.push(null);
        return r;
    };

    function Writable(opts) {
        Stream.call(this, opts);
        this.writable = true;
        this.writableEnded = false;
        this._writeImpl = opts && opts.write;
        this._finalImpl = opts && opts.final;
        this._pending = [];
        this._writing = false;
        this._ending = false;
        this._finished = false;
        this._endCb = null;
        this._writableState = { finished: false, errorEmitted: false, ended: false, needDrain: false };
    }
    Writable.prototype = Object.create(Stream.prototype);
    Writable.prototype.constructor = Writable;
    Writable.prototype._write = function (chunk, enc, cb) { cb(); };
    Writable.prototype.write = function (chunk, enc, cb) {
        if (typeof enc === 'function') { cb = enc; enc = undefined; }
        if (!this.writable && !(this._writing || this._pending.length > 0)) {
            var err = new Error('write after end');
            if (cb) cb(err); else this.emit('error', err);
            return false;
        }
        var self = this;
        var done = false;
        var callback = function (e) {
            if (done) return;
            done = true;
            if (e) { self.emit('error', e); if (cb) cb(e); return; }
            if (cb) cb();
        };
        if (this._writing) this._pending.push({ chunk: chunk, cb: callback });
        else this._dispatch(chunk, enc, callback);
        return true;
    };
    Writable.prototype._dispatch = function (chunk, enc, callback) {
        var self = this;
        this._writing = true;
        var impl = this._writeImpl || this._write;
        impl.call(this, chunk, enc, function (e) {
            self._writing = false;
            callback(e);
            if (self._pending.length) {
                var next = self._pending.shift();
                self._dispatch(next.chunk, undefined, next.cb);
            } else {
                self.emit('drain');
                self._maybeFinish();
            }
        });
    };
    Writable.prototype._maybeFinish = function () {
        if (!this._ending || this._finished || this._writing || this._pending.length) return;
        this._finished = true;
        this._writableState.finished = true;
        var self = this;
        var done = function () {
            self.emit('finish');
            if (self._endCb) { var cb = self._endCb; self._endCb = null; cb(); }
        };
        if (this._finalImpl) this._finalImpl.call(this, done);
        else if (this._final && this._final !== Writable.prototype._final) this._final.call(this, done);
        else done();
    };
    Writable.prototype.end = function (chunk, enc, cb) {
        if (typeof chunk === 'function') { cb = chunk; chunk = undefined; }
        if (typeof enc === 'function') { cb = enc; enc = undefined; }
        if (chunk !== undefined && chunk !== null) this.write(chunk, enc);
        this.writable = false;
        this.writableEnded = true;
        this._ending = true;
        this._endCb = cb || null;
        this._maybeFinish();
        return this;
    };
    Writable.prototype.destroy = function (err) {
        this.destroyed = true;
        if (err) this.emit('error', err);
        this.emit('close');
        return this;
    };

    function Duplex(opts) {
        Readable.call(this, opts);
        Writable.call(this, opts);
    }
    Duplex.prototype = Object.create(Readable.prototype);
    for (var dk in Writable.prototype)
        if (!(dk in Duplex.prototype)) Duplex.prototype[dk] = Writable.prototype[dk];
    Duplex.prototype.constructor = Duplex;

    function Transform(opts) {
        Duplex.call(this, opts);
        this._transformImpl = opts && opts.transform;
        var self = this;
        if (!(opts && typeof opts.final === 'function'))
            this._finalImpl = function (cb) { self.push(null); cb(); };
    }
    Transform.prototype = Object.create(Duplex.prototype);
    Transform.prototype.constructor = Transform;
    Transform.prototype._transform = function (chunk, enc, cb) { cb(null, chunk); };
    Transform.prototype._write = function (chunk, enc, cb) {
        var self = this;
        var impl = this._transformImpl || this._transform;
        impl.call(this, chunk, enc, function (err, out) {
            if (err) return cb(err);
            if (out !== undefined && out !== null) self.push(out);
            cb();
        });
    };
    Transform.prototype._final = function (cb) { this.push(null); cb(); };

    function pipeline() {
        var args = Array.prototype.slice.call(arguments);
        var cb = typeof args[args.length - 1] === 'function' ? args.pop() : function () {};
        if (args.length < 2) { queueMicrotask(function () { cb(new TypeError('pipeline requires at least two streams')); }); return; }
        var streams = args;
        var called = false;
        function finish(err) { if (called) return; called = true; cb(err || null); }
        for (var i = 0; i < streams.length - 1; i++) streams[i].pipe(streams[i + 1]);
        for (var j = 0; j < streams.length; j++) streams[j].once('error', finish);
        var last = streams[streams.length - 1];
        last.once('finish', function () { finish(); });
        last.once('end', function () { finish(); });
        last.once('close', function () { finish(); });
    }

    function finished(stream, cb) {
        var done = false;
        function onEnd() { finish(); }
        function onFinish() { finish(); }
        function onError(err) { finish(err); }
        function onClose() { finish(); }
        function cleanup() {
            stream.removeListener('end', onEnd);
            stream.removeListener('finish', onFinish);
            stream.removeListener('error', onError);
            stream.removeListener('close', onClose);
        }
        function finish(err) { if (done) return; done = true; cleanup(); cb(err || null); }
        // An already-finished stream resolves now: Node's finished() does not
        // wait for an event that has already fired.
        if (stream.readableEnded || stream.writableEnded || stream.destroyed) {
            queueMicrotask(function () { finish(); });
            return function () {};
        }
        stream.once('end', onEnd);
        stream.once('finish', onFinish);
        stream.once('error', onError);
        stream.once('close', onClose);
        // Node returns a cleanup function; it also keeps a long-lived stream
        // from accumulating one listener set per finished() call.
        return cleanup;
    }

    // Node's `require('stream')` is the legacy Stream constructor itself,
    // with the concrete classes attached as properties. The constructor and
    // prototype are declared once at the top of this file — a second
    // function declaration here would hoist over it and silently drop
    // Stream.prototype.pipe.
    Stream.Stream = Stream;
    Stream.Readable = Readable;
    Stream.Writable = Writable;
    Stream.Duplex = Duplex;
    Stream.Transform = Transform;
    Stream.PassThrough = function (opts) { Transform.call(this, opts); };
    Stream.PassThrough.prototype = Object.create(Transform.prototype);
    Stream.PassThrough.prototype.constructor = Stream.PassThrough;
    Stream.pipeline = pipeline;
    Stream.finished = finished;

    function ReadableStream(source) {
        source = source || {};
        var self = this;
        this._source = source;
        this._queue = [];
        this._pending = [];
        this._closed = false;
        this._error = null;
        this._pulling = false;
        this._controller = {
            enqueue: function (chunk) {
                if (self._closed || self._error) return;
                self._queue.push(chunk);
                self._flush();
            },
            close: function () { self._closed = true; self._flush(); },
            error: function (e) { self._error = e || new Error('stream error'); self._flush(); }
        };
        Object.defineProperty(this._controller, 'desiredSize', {
            get: function () { return 1 - self._queue.length; }
        });
        Promise.resolve(source.start ? source.start(this._controller) : undefined)
            .catch(function (e) { self._controller.error(e); });
    }
    ReadableStream.prototype._flush = function () {
        while (this._pending.length) {
            if (this._queue.length) {
                var p = this._pending.shift();
                p.resolve({ value: this._queue.shift(), done: false });
                continue;
            }
            if (this._error) { this._pending.shift().reject(this._error); continue; }
            if (this._closed) { this._pending.shift().resolve({ value: undefined, done: true }); continue; }
            break;
        }
        this._maybePull();
    };
    ReadableStream.prototype._maybePull = function () {
        var self = this;
        if (this._pulling || this._closed || this._error || this._queue.length > 0) return;
        if (!this._source.pull) return;
        this._pulling = true;
        Promise.resolve(this._source.pull(this._controller)).then(
            function () { self._pulling = false; },
            function (e) { self._pulling = false; self._controller.error(e); });
    };
    ReadableStream.prototype.getReader = function () {
        var self = this;
        return {
            read: function () {
                return new Promise(function (resolve, reject) {
                    self._pending.push({ resolve: resolve, reject: reject });
                    self._flush();
                });
            },
            cancel: function (reason) {
                self._closed = true;
                self._flush();
                return Promise.resolve(self._source.cancel ? self._source.cancel(reason) : undefined);
            },
            releaseLock: function () {}
        };
    };
    ReadableStream.prototype.pipeTo = function (dest) {
        var reader = this.getReader();
        var writer = dest.getWriter();
        function pump() {
            return reader.read().then(function (r) {
                if (r.done) return writer.close();
                return writer.write(r.value).then(pump);
            });
        }
        return pump();
    };
    ReadableStream.prototype[Symbol.asyncIterator] = function () {
        var reader = this.getReader();
        return { next: function () { return reader.read(); } };
    };

    function WritableStream(sink) {
        this._sink = sink || {};
        this._chain = Promise.resolve();
        this._closed = false;
    }
    WritableStream.prototype.getWriter = function () {
        var self = this;
        return {
            write: function (chunk) {
                if (self._closed) return Promise.reject(new Error('write after close'));
                self._chain = self._chain.then(function () {
                    return self._sink.write ? self._sink.write(chunk) : undefined;
                });
                return self._chain;
            },
            close: function () {
                if (self._closed) return Promise.resolve();
                self._closed = true;
                self._chain = self._chain.then(function () {
                    return self._sink.close ? self._sink.close() : undefined;
                });
                return self._chain;
            },
            abort: function (reason) {
                self._closed = true;
                return Promise.resolve(self._sink.abort ? self._sink.abort(reason) : undefined);
            },
            releaseLock: function () {}
        };
    };

    function TransformStream(transformer) {
        transformer = transformer || {};
        var controller = null;
        this.readable = new ReadableStream({
            start: function (c) { controller = c; },
            pull: function () { return undefined; }
        });
        this.writable = new WritableStream({
            write: function (chunk) {
                var out = transformer.transform ? transformer.transform(chunk, controller) : chunk;
                if (out !== undefined) controller.enqueue(out);
                return undefined;
            },
            close: function () {
                if (transformer.flush) {
                    var out = transformer.flush(controller);
                    if (out !== undefined) controller.enqueue(out);
                }
                controller.close();
            }
        });
    }

    var streamWebModule = {
        ReadableStream: ReadableStream,
        WritableStream: WritableStream,
        TransformStream: TransformStream
    };

    Readable.toWeb = function (stream) {
        var paused = false;
        return new ReadableStream({
            start: function (controller) {
                stream.on('data', function (chunk) {
                    controller.enqueue(chunk);
                    if (controller.desiredSize <= 0 && stream.pause) {
                        paused = true;
                        stream.pause();
                    }
                });
                stream.on('end', function () { controller.close(); });
                stream.on('error', function (e) { controller.error(e); });
                if (stream.resume) stream.resume();
            },
            pull: function () {
                if (paused && stream.resume) { paused = false; stream.resume(); }
            },
            cancel: function () { if (stream.destroy) stream.destroy(); }
        });
    };
    Readable.fromWeb = function (webStream, options) {
        var objectMode = !!(options && options.objectMode);
        var r = new Readable();
        var reader = webStream.getReader();
        function pump() {
            reader.read().then(function (result) {
                if (result.done) { r.push(null); return; }
                var value = result.value;
                if (!objectMode && !Buffer.isBuffer(value)) value = Buffer.from(value);
                r.push(value);
                pump();
            }, function (e) { r.destroy(e); });
        }
        pump();
        return r;
    };
    Writable.toWeb = function (stream) {
        return new WritableStream({
            write: function (chunk) {
                return new Promise(function (resolve, reject) {
                    stream.write(chunk, function (err) { if (err) reject(err); else resolve(); });
                });
            },
            close: function () {
                return new Promise(function (resolve, reject) {
                    stream.end(function (err) { if (err) reject(err); else resolve(); });
                });
            },
            abort: function (reason) { if (stream.destroy) stream.destroy(reason); }
        });
    };
    Writable.fromWeb = function (webStream) {
        var writer = webStream.getWriter();
        var w = new Writable({
            write: function (chunk, enc, cb) { writer.write(chunk).then(function () { cb(); }, cb); },
            final: function (cb) { writer.close().then(function () { cb(); }, cb); }
        });
        var baseDestroy = w.destroy;
        w.destroy = function (err) {
            if (writer.abort) writer.abort(err);
            return baseDestroy.call(w, err);
        };
        return w;
    };
    Duplex.toWeb = function (stream) {
        return { readable: Readable.toWeb(stream), writable: Writable.toWeb(stream) };
    };
    Stream.addAbortSignal = function (signal, stream) {
        if (!signal) return stream;
        var onAbort = function () {
            var e = new Error('The operation was aborted');
            e.name = 'AbortError';
            e.code = 'ABORT_ERR';
            if (stream.destroy) stream.destroy(e);
            else if (stream.emit) stream.emit('error', e);
        };
        if (signal.aborted) queueMicrotask(onAbort);
        else signal.addEventListener('abort', onAbort);
        return stream;
    };
    Stream.Readable.toWeb = Readable.toWeb;
    Stream.Readable.fromWeb = Readable.fromWeb;
    Stream.Writable.toWeb = Writable.toWeb;
    Stream.Writable.fromWeb = Writable.fromWeb;

    // Node's documented defaults; the prelude does not implement backpressure
    // limits, so these are informational for packages that query them.
    var defaultHighWaterMark = 16384;
    var defaultHighWaterMarkObjectMode = 16;
    Stream.getDefaultHighWaterMark = function (objectMode) {
        return objectMode ? defaultHighWaterMarkObjectMode : defaultHighWaterMark;
    };
    Stream.setDefaultHighWaterMark = function (objectMode, value) {
        if (objectMode) defaultHighWaterMarkObjectMode = value;
        else defaultHighWaterMark = value;
    };

    var streamModule = Stream;

    // ---- url -----------------------------------------------------------

    function URLSearchParams(init) {
        this._pairs = [];
        if (typeof init === 'string') {
            var s = init.charAt(0) === '?' ? init.slice(1) : init;
            if (s) {
                var parts = s.split('&');
                for (var i = 0; i < parts.length; i++) {
                    if (!parts[i]) continue;
                    var eq = parts[i].indexOf('=');
                    var k = eq < 0 ? parts[i] : parts[i].slice(0, eq);
                    var v = eq < 0 ? '' : parts[i].slice(eq + 1);
                    this._pairs.push([decodeURIComponent(k.replace(/\+/g, ' ')), decodeURIComponent(v.replace(/\+/g, ' '))]);
                }
            }
        } else if (init && typeof init === 'object') {
            var keys = Object.keys(init);
            for (var j = 0; j < keys.length; j++) this._pairs.push([keys[j], String(init[keys[j]])]);
        }
    }
    URLSearchParams.prototype.append = function (k, v) { this._pairs.push([String(k), String(v)]); };
    URLSearchParams.prototype.get = function (k) {
        for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === k) return this._pairs[i][1];
        return null;
    };
    URLSearchParams.prototype.getAll = function (k) {
        var out = [];
        for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === k) out.push(this._pairs[i][1]);
        return out;
    };
    URLSearchParams.prototype.has = function (k) { return this.get(k) !== null; };
    URLSearchParams.prototype.set = function (k, v) {
        var found = false;
        var out = [];
        for (var i = 0; i < this._pairs.length; i++) {
            if (this._pairs[i][0] === k) { if (!found) { out.push([String(k), String(v)]); found = true; } }
            else out.push(this._pairs[i]);
        }
        if (!found) out.push([String(k), String(v)]);
        this._pairs = out;
    };
    URLSearchParams.prototype['delete'] = function (k) {
        this._pairs = this._pairs.filter(function (p) { return p[0] !== k; });
    };
    URLSearchParams.prototype.keys = function () { return this._pairs.map(function (p) { return p[0]; })[Symbol.iterator](); };
    URLSearchParams.prototype.values = function () { return this._pairs.map(function (p) { return p[1]; })[Symbol.iterator](); };
    URLSearchParams.prototype.entries = function () { return this._pairs.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
    URLSearchParams.prototype.forEach = function (fn, thisArg) {
        for (var i = 0; i < this._pairs.length; i++) fn.call(thisArg, this._pairs[i][1], this._pairs[i][0], this);
    };
    URLSearchParams.prototype.toString = function () {
        return this._pairs.map(function (p) {
            return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
        }).join('&');
    };
    URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;

    function parseURL(input, base) {
        var raw = String(input);
        var m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(\/\/)?([^\/?#]*)?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/.exec(raw);
        if (!m) {
            if (base) {
                var b = parseURL(base);
                if (raw.charAt(0) === '/') raw = b.protocol + '//' + b.host + raw;
                else if (raw.charAt(0) === '#') raw = b.href.split('#')[0] + raw;
                else if (raw.charAt(0) === '?') raw = b.href.split('?')[0] + raw;
                else raw = b.protocol + '//' + b.host + b.pathname.replace(/[^\/]*$/, '') + raw;
                return parseURL(raw);
            }
            throw new TypeError('Invalid URL');
        }
        var protocol = m[1].toLowerCase();
        var hasAuth = !!m[2];
        var authority = m[3] || '';
        var pathname = m[4] || (hasAuth ? '/' : '');
        var search = m[5] || '';
        var hash = m[6] || '';
        var username = '', password = '', host = authority;
        var at = authority.lastIndexOf('@');
        if (at >= 0) {
            var userinfo = authority.slice(0, at).split(':');
            username = decodeURIComponent(userinfo[0] || '');
            password = decodeURIComponent(userinfo[1] || '');
            host = authority.slice(at + 1);
        }
        var hostname = host, port = '';
        if (host.charAt(0) === '[') {
            var close = host.indexOf(']');
            hostname = host.slice(0, close + 1);
            if (host.charAt(close + 1) === ':') port = host.slice(close + 2);
        } else {
            var colon = host.lastIndexOf(':');
            if (colon >= 0) { hostname = host.slice(0, colon); port = host.slice(colon + 1); }
        }
        return {
            protocol: protocol, username: username, password: password,
            hostname: hostname, port: port || '', host: host,
            pathname: pathname || '/', search: search, hash: hash,
            origin: hasAuth && protocol !== 'file:' ? protocol + '//' + host : 'null',
            href: protocol + (hasAuth ? '//' : '') + authority + pathname + search + hash,
            searchParams: new URLSearchParams(search)
        };
    }

    function URL(input, base) {
        var p = parseURL(input, base);
        for (var k in p) this[k] = p[k];
        Object.defineProperty(this, 'search', {
            enumerable: true,
            get: function () {
                var q = this.searchParams.toString();
                return q ? '?' + q : '';
            }
        });
        Object.defineProperty(this, 'href', {
            enumerable: true,
            get: function () {
                var auth = '';
                if (this.username) auth = this.username + (this.password ? ':' + this.password : '') + '@';
                var hasHost = this.host.length > 0;
                return this.protocol + (hasHost ? '//' : '') + auth + this.host +
                    this.pathname + this.search + this.hash;
            }
        });
        if (!(this instanceof URL)) return new URL(input, base);
    }
    URL.prototype.toString = function () { return this.href; };
    URL.prototype.toJSON = URL.prototype.toString;
    URL.canParse = function (input, base) {
        try { parseURL(input, base); return true; } catch (e) { return false; }
    };

    function urlParse(input, parseQuery) {
        var p = parseURL(input);
        var out = {
            protocol: p.protocol, slashes: p.host ? true : false,
            auth: p.username ? p.username + (p.password ? ':' + p.password : '') : null,
            host: p.host, port: p.port, hostname: p.hostname,
            hash: p.hash, search: p.search, query: p.search ? p.search.slice(1) : null,
            pathname: p.pathname, path: p.pathname + p.search, href: p.href
        };
        if (parseQuery) out.query = new URLSearchParams(p.search);
        return out;
    }
    function urlFormat(u) {
        var auth = u.auth ? u.auth + '@' : '';
        var host = u.host || ((u.hostname || '') + (u.port ? ':' + u.port : ''));
        var query = u.query;
        if (query && typeof query === 'object') query = new URLSearchParams(query).toString();
        var search = u.search || (query ? '?' + query : '');
        return (u.protocol || '') + (u.slashes ? '//' : '') + auth + host + (u.pathname || '') + search + (u.hash || '');
    }

    var urlModule = {
        URL: URL,
        URLSearchParams: URLSearchParams,
        parse: urlParse,
        format: urlFormat,
        resolve: function (from, to) { return new URL(to, from).href; },
        fileURLToPath: function (input) {
            var u = input instanceof URL ? input : new URL(String(input));
            if (u.protocol !== 'file:') throw new TypeError('The URL must be of scheme file');
            var p = decodeURIComponent(u.pathname);
            if (u.hostname && u.hostname !== 'localhost') p = '//' + u.hostname + p;
            return p;
        },
        urlToHttpOptions: function (input) {
            var u = input instanceof URL ? input : new URL(String(input));
            var opts = {
                protocol: u.protocol,
                hostname: u.hostname.charAt(0) === '[' ? u.hostname.slice(1, -1) : u.hostname,
                hash: u.hash,
                search: u.search,
                pathname: u.pathname,
                path: u.pathname + u.search,
                href: u.href
            };
            if (u.port !== '') opts.port = Number(u.port);
            if (u.username || u.password) {
                opts.auth = decodeURIComponent(u.username) + ':' + decodeURIComponent(u.password);
            }
            return opts;
        },
        pathToFileURL: function (filepath) {
            var abs = pathModule.resolve(String(filepath));
            var enc = abs.split('/').map(function (part) { return encodeURIComponent(part).replace(/%2F/g, '/'); }).join('/');
            return new URL('file://' + enc);
        }
    };

