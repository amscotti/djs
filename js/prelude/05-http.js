    // ---- http client (plain HTTP in v0.7) ------------------------------

    function normalizeHttpOptions(input, extra) {
        if (typeof input === 'string') {
            var u = new URL(input);
            var o = {
                protocol: u.protocol, hostname: u.hostname,
                port: u.port || (u.protocol === 'https:' ? 443 : 80), path: u.pathname + (u.search || ''),
                method: 'GET', headers: {}
            };
            if (extra) for (var k in extra) o[k] = extra[k];
            return o;
        }
        var out = {};
        for (var k2 in input) out[k2] = input[k2];
        out.hostname = out.hostname || out.host || 'localhost';
        out.port = Number(out.port || (out.protocol === 'https:' ? 443 : 80));
        out.path = out.path || '/';
        out.method = (out.method || 'GET').toUpperCase();
        out.headers = out.headers || {};
        out.protocol = out.protocol || 'http:';
        return out;
    }

    function findBytes(buf, bytes, from) {
        from = from || 0;
        outer: for (var i = from; i <= buf.length - bytes.length; i++) {
            for (var j = 0; j < bytes.length; j++) if (buf[i + j] !== bytes[j]) continue outer;
            return i;
        }
        return -1;
    }

    function headerMap(raw) {
        var out = {};
        var lines = raw.split('\r\n');
        for (var i = 0; i < lines.length; i++) {
            var idx = lines[i].indexOf(':');
            if (idx <= 0) continue;
            var k = lines[i].slice(0, idx).trim().toLowerCase();
            var v = lines[i].slice(idx + 1).trim();
            if (k === 'set-cookie') {
                // Repeated Set-Cookie must stay separate, as in Node.
                if (out[k] === undefined) out[k] = [v];
                else out[k].push(v);
            } else {
                out[k] = out[k] === undefined ? v : out[k] + ', ' + v;
            }
        }
        return out;
    }

    function decodeChunked(body) {
        var out = [];
        var pos = 0;
        var text = body.toString('latin1');
        while (pos < text.length) {
            var lineEnd = text.indexOf('\r\n', pos);
            if (lineEnd < 0) { var e1 = new Error('malformed chunked body'); e1.code = 'ERR_HTTP_INVALID_BODY'; throw e1; }
            var sizeText = text.slice(pos, lineEnd).split(';')[0].trim();
            if (!/^[0-9a-fA-F]+$/.test(sizeText)) { var e2 = new Error('malformed chunk size'); e2.code = 'ERR_HTTP_INVALID_BODY'; throw e2; }
            var size = parseInt(sizeText, 16);
            if (!size) return Buffer.concat(out);
            pos = lineEnd + 2;
            if (pos + size + 2 > body.length) { var e3 = new Error('truncated chunked body'); e3.code = 'ERR_HTTP_BODY_TRUNCATED'; throw e3; }
            out.push(body.slice(pos, pos + size));
            pos += size + 2;
        }
        var e4 = new Error('truncated chunked body'); e4.code = 'ERR_HTTP_BODY_TRUNCATED'; throw e4;
    }

    function IncomingMessage(statusCode, statusMessage, headers) {
        Readable.call(this);
        this.statusCode = statusCode;
        this.statusMessage = statusMessage;
        this.headers = headers;
        this.httpVersion = '1.1';
        this.complete = false;
    }
    IncomingMessage.prototype = Object.create(Readable.prototype);
    IncomingMessage.prototype.constructor = IncomingMessage;

    function ClientRequest(options) {
        EventEmitter.call(this);
        this.options = options;
        this._chunks = [];
        this._headers = {};
        var hdrs = options.headers || {};
        if (hdrs instanceof FetchHeaders) {
            var self0 = this;
            hdrs.forEach(function (v, k) { self0._headers[String(k).toLowerCase()] = v; });
        } else {
            for (var k in hdrs) if (Object.prototype.hasOwnProperty.call(hdrs, k)) this._headers[k.toLowerCase()] = hdrs[k];
        }
        this.method = options.method;
        this.path = options.path;
        this._ended = false;
    }
    ClientRequest.prototype = Object.create(EventEmitter.prototype);
    ClientRequest.prototype.constructor = ClientRequest;
    function checkHeader(k, v) {
        if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(String(k))) {
            var ke = new Error('invalid HTTP header name'); ke.code = 'ERR_INVALID_HTTP_TOKEN'; throw ke;
        }
        var text = String(v);
        if (/[\r\n\0]/.test(text)) {
            var idx = text.search(/[\r\n\0]/);
            var ve = new Error('invalid character in HTTP header value: ' + String(k) + ' len=' + text.length + ' at=' + idx + ' code=' + text.charCodeAt(idx)); ve.code = 'ERR_INVALID_CHAR'; throw ve;
        }
        return text;
    }
    ClientRequest.prototype.setHeader = function (k, v) { this._headers[String(k).toLowerCase()] = checkHeader(k, v); return this; };
    ClientRequest.prototype.getHeader = function (k) { return this._headers[String(k).toLowerCase()]; };
    ClientRequest.prototype.removeHeader = function (k) { delete this._headers[String(k).toLowerCase()]; return this; };
    ClientRequest.prototype.write = function (data, enc) {
        this._chunks.push(typeof data === 'string' ? Buffer.from(data, enc || 'utf8') : Buffer.from(data));
        return true;
    };
    ClientRequest.prototype.abort = ClientRequest.prototype.destroy = function () {
        this._aborted = true;
        if (this._timeout) { clearTimeout(this._timeout); this._timeout = null; }
        if (this.socket) this.socket.destroy();
        this.emit('abort');
        return this;
    };
    ClientRequest.prototype.setTimeout = function (ms, callback) {
        var self = this;
        ms = Number(ms);
        if (typeof callback === 'function') this.once('timeout', callback);
        if (this._timeout) clearTimeout(this._timeout);
        this._timeout = setTimeout(function () {
            self._timeout = null;
            self.emit('timeout');
        }, ms);
        if (this.socket && typeof this.socket.setTimeout === 'function') this.socket.setTimeout(ms);
        return this;
    };
    ClientRequest.prototype.setNoDelay = function (noDelay) {
        if (this.socket && typeof this.socket.setNoDelay === 'function') this.socket.setNoDelay(noDelay);
        this._noDelay = noDelay !== false;
        return this;
    };
    ClientRequest.prototype.setSocketKeepAlive = function () { return this; };
    ClientRequest.prototype.flushHeaders = function () { return this; };
    ClientRequest.prototype._createSocket = function () {
        var o = this.options;
        var agent = this._agent;
        if (agent && typeof agent.createConnection === 'function') {
            return agent.createConnection({
                port: o.port,
                host: o.hostname,
                hostname: o.hostname,
                protocol: o.protocol,
                servername: o.servername,
                rejectUnauthorized: o.rejectUnauthorized,
                ca: o.ca, caFile: o.caFile,
                cert: o.cert, certFile: o.certFile,
                key: o.key, keyFile: o.keyFile,
                alpn: o.alpn
            });
        }
        return o.protocol === 'https:'
            ? tlsModule.connect({
                port: o.port,
                host: o.hostname,
                servername: o.servername || o.hostname,
                rejectUnauthorized: o.rejectUnauthorized !== false,
                ca: o.ca, caFile: o.caFile,
                cert: o.cert, certFile: o.certFile,
                key: o.key, keyFile: o.keyFile,
                alpn: o.alpn
              })
            : netModule.connect(o.port, o.hostname);
    };
    ClientRequest.prototype.end = function (data, enc) {
        if (data !== undefined && data !== null) this.write(data, enc);
        if (this._ended || this._aborted) return this;
        this._ended = true;
        var body = Buffer.concat(this._chunks);
        var headers = this._headers;
        headers.host = headers.host || this.options.hostname;
        var agent = this.options.agent === false ? null : (this.options.agent || defaultAgentFor(this.options));
        if (agent && agent.keepAlive) headers.connection = headers.connection || 'keep-alive';
        else headers.connection = headers.connection || 'close';
        this._connection = String(headers.connection).toLowerCase();
        this._keepAlive = this._connection !== 'close' && this._connection !== 'upgrade';
        if (!headers['content-length'] && body.length) headers['content-length'] = String(body.length);
        for (var hk in headers) headers[hk] = checkHeader(hk, headers[hk]);
        // The request line is assembled verbatim; validate the method token
        // and the path so neither can carry CR/LF/NUL into the wire format.
        if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(String(this.method))) {
            var mErr = new Error('invalid HTTP method'); mErr.code = 'ERR_INVALID_HTTP_TOKEN'; throw mErr;
        }
        if (/[\r\n\0]/.test(String(this.path))) {
            var pErr = new Error('invalid character in HTTP path'); pErr.code = 'ERR_UNESCAPED_CHAR'; throw pErr;
        }
        var head = this.method + ' ' + this.path + ' HTTP/1.1\r\n';
        for (var h in headers) head += h + ': ' + headers[h] + '\r\n';
        head += '\r\n';
        this._raw = Buffer.concat([Buffer.from(head, 'utf8'), body]);
        this._agent = agent;
        this._agentName = null;
        this._socketStarted = false;
        this._detach = null;
        if (!agent || typeof agent.addRequest !== 'function') {
            this._start(this._createSocket(), false, null, null);
        } else {
            agent.addRequest(this, this.options);
        }
        return this;
    };
    ClientRequest.prototype._start = function (socket, reused, agent, name) {
        if (this._aborted) { socket.destroy(); return this; }
        var self = this;
        this._socketStarted = true;
        this.socket = socket;
        this._agent = agent;
        this._agentName = name;
        this._reused = !!reused;
        var raw = this._raw;
        var sent = false;
        function send() {
            if (sent) return;
            sent = true;
            if (self._aborted) { socket.destroy(); return; }
            socket.write(raw);
        }
        var state = {
            headBuf: null,
            msg: null,
            mode: "close",
            remaining: 0,
            chunkBuf: Buffer.alloc(0),
            chunkPhase: "size",
            done: false,
            total: 0,
            reusable: true
        };
        function clearRequestTimer() {
            if (self._timeout) { clearTimeout(self._timeout); self._timeout = null; }
        }
        function detach() {
            socket.removeListener("data", onData);
            socket.removeListener("end", onEnd);
            socket.removeListener("error", onError);
            socket.removeListener("close", onClose);
            socket.removeListener("connect", send);
        }
        function release(reusable) {
            detach();
            if (self._detach === detach) self._detach = null;
            if (self.socket === socket) self.socket = null;
            var a = self._agent;
            var n = self._agentName;
            self._agentName = null;
            if (a) a.releaseSocket(socket, n, reusable);
            else socket.destroy();
        }
        function finishResponse() {
            if (state.done) return;
            state.done = true;
            clearRequestTimer();
            if (state.msg) { state.msg.complete = true; state.msg.push(null); }
            release(state.reusable && self._keepAlive);
        }
        function failResponse(err) {
            if (state.done) return;
            state.done = true;
            clearRequestTimer();
            detach();
            if (self._detach === detach) self._detach = null;
            if (self.socket === socket) self.socket = null;
            var a = self._agent;
            var n = self._agentName;
            self._agentName = null;
            socket.destroy();
            if (a) a.releaseSocket(socket, n, false);
            self.emit("error", err);
        }
        function pushBody(buf) {
            if (!buf || !buf.length || state.done) return;
            state.total += buf.length;
            if (state.total > 64 * 1024 * 1024) {
                var be = new Error("HTTP body too large"); be.code = "ERR_HTTP_BODY_TOO_LARGE"; failResponse(be); return;
            }
            state.msg.push(buf);
        }
        function parseHead(buf, sep) {
            var headText = buf.slice(0, sep).toString("utf8");
            var lines = headText.split("\r\n");
            var statusLine = lines.shift().split(" ");
            var statusCode = Number(statusLine[1] || 0);
            if (!statusCode) { var me0 = new Error("malformed HTTP status line"); me0.code = "ERR_HTTP_INVALID_RESPONSE"; throw me0; }
            var message = new IncomingMessage(statusCode, statusLine.slice(2).join(" "), headerMap(lines.join("\r\n")));
            message.httpVersion = String(statusLine[0] || "HTTP/1.1").replace(/^HTTP\//, "");
            state.msg = message;
            var conn = String(message.headers["connection"] || "").toLowerCase();
            var connTokens = conn.split(",").map(function (s) { return s.trim(); });
            if (connTokens.indexOf("close") >= 0) state.reusable = false;
            if (message.httpVersion === "1.0" && connTokens.indexOf("keep-alive") < 0) state.reusable = false;
            if (statusCode === 101) { state.mode = "upgrade"; state.reusable = false; return; }
            var te = (message.headers["transfer-encoding"] || "").toLowerCase();
            var cl = message.headers["content-length"];
            if (self.method === "HEAD" || statusCode === 204 || statusCode === 304) state.mode = "none";
            else if (te === "chunked") state.mode = "chunked";
            else if (cl !== undefined) { state.mode = "length"; state.remaining = Number(cl); }
            else { state.mode = "close"; state.reusable = false; }
            self.emit("response", message);
            if (state.mode === "none") { finishResponse(); return; }
            if (state.mode === "length" && state.remaining <= 0) finishResponse();
        }
        function consumeChunked() {
            for (;;) {
                if (state.done) return;
                if (state.chunkPhase === "size") {
                    var nl = findBytes(state.chunkBuf, [13, 10]);
                    if (nl < 0) {
                        if (state.chunkBuf.length > 8192) {
                            var se = new Error("malformed chunk size"); se.code = "ERR_HTTP_INVALID_BODY"; failResponse(se);
                        }
                        return;
                    }
                    var line = state.chunkBuf.slice(0, nl).toString("latin1").split(";")[0].trim();
                    if (!/^[0-9a-fA-F]+$/.test(line)) {
                        var e2 = new Error("malformed chunk size"); e2.code = "ERR_HTTP_INVALID_BODY"; failResponse(e2); return;
                    }
                    var size = parseInt(line, 16);
                    state.chunkBuf = state.chunkBuf.slice(nl + 2);
                    if (!size) { state.chunkDone = true; finishResponse(); return; }
                    // A single announced chunk is bounded: an unbounded size
                    // would buffer the announced length before pushBody's
                    // total cap ever sees a byte.
                    if (size > 8 * 1024 * 1024) {
                        var ce = new Error("HTTP chunk too large"); ce.code = "ERR_HTTP_BODY_TOO_LARGE"; failResponse(ce); return;
                    }
                    state.remaining = size;
                    state.chunkPhase = "data";
                } else {
                    if (state.chunkBuf.length < state.remaining + 2) {
                        // Bound the wait for chunk + CRLF as well (a hostile
                        // server can announce and drip indefinitely).
                        if (state.chunkBuf.length > 16 * 1024 * 1024) {
                            var de = new Error("HTTP chunk too large"); de.code = "ERR_HTTP_BODY_TOO_LARGE"; failResponse(de);
                        }
                        return;
                    }
                    var part = state.chunkBuf.slice(0, state.remaining);
                    // The two framing bytes must be CR LF, not more data.
                    if (state.chunkBuf[state.remaining] !== 13 || state.chunkBuf[state.remaining + 1] !== 10) {
                        var fe = new Error("malformed chunk framing"); fe.code = "ERR_HTTP_INVALID_BODY"; failResponse(fe); return;
                    }
                    state.chunkBuf = state.chunkBuf.slice(state.remaining + 2);
                    state.remaining = 0;
                    state.chunkPhase = "size";
                    pushBody(part);
                }
            }
        }
        function onError(e) {
            if (state.done) return;
            failResponse(e);
        }
        function onClose() {
            if (state.done) return;
            // TLS reports EOF as close and may do so before the stream emits
            // end. For a close-delimited body that close *is* the boundary;
            // length/chunked bodies still incomplete here are truncation.
            if (state.msg && (state.mode === "close" || state.mode === "none")) {
                finishResponse();
                return;
            }
            var e = new Error("socket closed before response");
            e.code = "ECONNRESET";
            failResponse(e);
        }
        function onData(chunk) {
            if (state.done) return;
            var data = chunk;
            if (!state.msg) {
                state.headBuf = state.headBuf ? Buffer.concat([state.headBuf, data]) : data;
                var sep = findBytes(state.headBuf, [13, 10, 13, 10]);
                if (sep < 0) {
                    if (state.headBuf.length > 16384) {
                        var he = new Error("HTTP headers too large"); he.code = "ERR_HTTP_HEADERS_TOO_LARGE"; failResponse(he);
                    }
                    return;
                }
                if (sep > 16384) {
                    var he2 = new Error("HTTP headers too large"); he2.code = "ERR_HTTP_HEADERS_TOO_LARGE"; failResponse(he2); return;
                }
                data = state.headBuf.slice(sep + 4);
                try { parseHead(state.headBuf, sep); } catch (e) { failResponse(e); return; }
                state.headBuf = null;
                if (state.mode === "upgrade") {
                    state.done = true;
                    clearRequestTimer();
                    detach();
                    if (self._detach === detach) self._detach = null;
                    if (self.socket === socket) self.socket = null;
                    if (self._agent) self._agent.forgetSocket(socket, self._agentName);
                    self._agentName = null;
                    self.emit("upgrade", state.msg, socket, data);
                    return;
                }
                if (state.done) return;
            }
            if (state.mode === "none") return;
            if (state.mode === "length") {
                if (state.remaining <= 0) { finishResponse(); return; }
                var take = data.length > state.remaining ? data.slice(0, state.remaining) : data;
                state.remaining -= take.length;
                pushBody(take);
                if (state.remaining <= 0 && !state.done) finishResponse();
                return;
            }
            if (state.mode === "chunked") {
                state.chunkBuf = state.chunkBuf.length ? Buffer.concat([state.chunkBuf, data]) : data;
                consumeChunked();
                return;
            }
            pushBody(data);
        }
        function onEnd() {
            if (state.done) return;
            if (!state.msg) {
                var me = new Error("malformed HTTP response"); me.code = "ERR_HTTP_INVALID_RESPONSE"; failResponse(me); return;
            }
            if (state.mode === "length" && state.remaining > 0) {
                var te = new Error("truncated HTTP body"); te.code = "ERR_HTTP_BODY_TRUNCATED"; failResponse(te); return;
            }
            // A chunked body is complete only after the terminal 0-size
            // chunk; a connection close mid-chunk is truncation, not EOF.
            if (state.mode === "chunked" && !state.chunkDone) {
                var ce = new Error("truncated HTTP body"); ce.code = "ERR_HTTP_BODY_TRUNCATED"; failResponse(ce); return;
            }
            finishResponse();
        }
        this._detach = detach;
        socket.on("data", onData);
        socket.on("end", onEnd);
        socket.on("error", onError);
        socket.on("close", onClose);
        if (reused || !socket.connecting) send();
        else socket.once("connect", send);
        return this;
    };
    ClientRequest.prototype.abort = ClientRequest.prototype.destroy = function () {
        this._aborted = true;
        if (this._timeout) { clearTimeout(this._timeout); this._timeout = null; }
        if (this._detach) { this._detach(); this._detach = null; }
        var socket = this.socket;
        this.socket = null;
        if (this._agent && !this._socketStarted) this._agent.removeRequest(this);
        if (socket) {
            socket.destroy();
            if (this._agent) this._agent.releaseSocket(socket, this._agentName, false);
        }
        this._agentName = null;
        this.emit('abort');
        return this;
    };

    function request(input, options, cb) {
        if (typeof options === 'function') { cb = options; options = {}; }
        var opts = normalizeHttpOptions(input, options);
        var req = new ClientRequest(opts);
        if (cb) req.once('response', cb);
        return req;
    }
    function get(input, options, cb) {
        var req = request(input, options, cb);
        req.end();
        return req;
    }

    // ---- http.Agent ---------------------------------------------------
    // A real keep-alive pool. Each origin has an active list, an idle/free
    // list and a FIFO request queue. Fetch uses the https global agent, so a
    // Promise.all over hundreds of URLs reuses a bounded number of
    // connections instead of paying DNS + TCP + TLS for every request.
    //
    // Idle sockets are unrefed: like Node, a pooled connection must not keep
    // the process alive after the script has finished.
    function Agent(options) {
        options = options || {};
        this.options = options;
        this.protocol = options.protocol || 'http:';
        this.defaultPort = options.defaultPort || (this.protocol === 'https:' ? 443 : 80);
        this.keepAlive = !!options.keepAlive;
        this.keepAliveMsecs = options.keepAliveMsecs === undefined ? 1000 : options.keepAliveMsecs;
        this.maxSockets = options.maxSockets === undefined ? Infinity : options.maxSockets;
        this.maxFreeSockets = options.maxFreeSockets === undefined ? 256 : options.maxFreeSockets;
        this.scheduling = options.scheduling || 'lifo';
        this.timeout = options.timeout;
        this.sockets = {};
        this.freeSockets = {};
        this.requests = {};
    }
    Agent.prototype.getName = function (options) {
        var o = options || {};
        var protocol = o.protocol || this.protocol;
        var host = String(o.hostname || o.host || 'localhost').toLowerCase();
        var port = Number(o.port || (protocol === 'https:' ? 443 : 80));
        var servername = o.servername || (protocol === 'https:' ? host : '');
        var verify = o.rejectUnauthorized === false ? '0' : '1';
        return protocol + '//' + host + ':' + port + '|' + servername + '|' + verify;
    };
    Agent.prototype._canPool = function (req, options) {
        if (!this.keepAlive || !req || !req._keepAlive) return false;
        if (req.method === 'CONNECT') return false;
        var o = options || {};
        // Per-request trust material makes reuse ambiguous; keep those
        // requests on a dedicated socket rather than risking a socket built
        // with a different CA or client certificate.
        if (o.ca || o.caFile || o.cert || o.certFile || o.key || o.keyFile || o.pfx || o.alpn) return false;
        return true;
    };
    Agent.prototype._clearIdle = function (socket) {
        if (!socket) return;
        if (socket._djsIdleTimer) { clearTimeout(socket._djsIdleTimer); socket._djsIdleTimer = null; }
        if (socket._djsIdleClose) { socket.removeListener('close', socket._djsIdleClose); socket._djsIdleClose = null; }
        if (socket._djsIdleError) { socket.removeListener('error', socket._djsIdleError); socket._djsIdleError = null; }
    };
    Agent.prototype._removeFree = function (socket, name) {
        var free = this.freeSockets[name];
        if (free) {
            var i = free.indexOf(socket);
            if (i >= 0) free.splice(i, 1);
        }
        this._clearIdle(socket);
    };
    Agent.prototype._watchIdle = function (socket, name) {
        var self = this;
        this._clearIdle(socket);
        socket._djsIdleTimer = setTimeout(function () {
            socket._djsIdleTimer = null;
            self._removeFree(socket, name);
            socket.destroy();
        }, this.keepAliveMsecs);
        if (socket._djsIdleTimer && typeof socket._djsIdleTimer.unref === 'function')
            socket._djsIdleTimer.unref();
        socket._djsIdleClose = function () { self._removeFree(socket, name); };
        socket.once('close', socket._djsIdleClose);
        socket._djsIdleError = function () {
            self._removeFree(socket, name);
            socket.destroy();
        };
        socket.on('error', socket._djsIdleError);
        if (typeof socket.unref === 'function') socket.unref();
    };
    Agent.prototype._nextRequest = function (name) {
        var queue = this.requests[name];
        if (!queue) return null;
        while (queue.length) {
            var entry = queue.shift();
            if (entry.req && !entry.req._aborted) return entry;
        }
        return null;
    };
    Agent.prototype.addRequest = function (req, options) {
        var name = this.getName(options);
        if (!this._canPool(req, options)) {
            var one = this.createConnection(options);
            req._start(one, false, this, null);
            return;
        }
        var free = this.freeSockets[name];
        while (free && free.length) {
            var socket = free.pop();
            this._clearIdle(socket);
            if (socket.destroyed || socket.connecting) { socket.destroy(); continue; }
            this.reuseSocket(socket, options);
            (this.sockets[name] || (this.sockets[name] = [])).push(socket);
            req._start(socket, true, this, name);
            return;
        }
        var active = this.sockets[name] || (this.sockets[name] = []);
        if (active.length < this.maxSockets) {
            var fresh = this.createConnection(options);
            active.push(fresh);
            req._start(fresh, false, this, name);
            return;
        }
        (this.requests[name] || (this.requests[name] = [])).push({ req: req, options: options });
    };
    Agent.prototype._dispatch = function (name) {
        if (this._destroying) return;
        var queue = this.requests[name];
        if (!queue || !queue.length) return;
        var active = this.sockets[name] || (this.sockets[name] = []);
        while (queue.length && active.length < this.maxSockets) {
            var entry = this._nextRequest(name);
            if (!entry) return;
            var socket;
            try { socket = this.createConnection(entry.options); }
            catch (e) { entry.req.emit('error', e); continue; }
            active.push(socket);
            entry.req._start(socket, false, this, name);
        }
    };
    Agent.prototype.releaseSocket = function (socket, name, reusable) {
        if (!socket) return;
        if (this._destroying) { socket.destroy(); return; }
        if (!name) { socket.destroy(); return; }
        var active = this.sockets[name];
        if (active) {
            var ai = active.indexOf(socket);
            if (ai >= 0) active.splice(ai, 1);
        }
        this._clearIdle(socket);
        if (this.keepAlive && reusable && !socket.destroyed) {
            var entry = this._nextRequest(name);
            if (entry) {
                this.reuseSocket(socket, entry.options);
                (this.sockets[name] || (this.sockets[name] = [])).push(socket);
                entry.req._start(socket, true, this, name);
                return;
            }
            var free = this.freeSockets[name] || (this.freeSockets[name] = []);
            if (free.length < this.maxFreeSockets) {
                this.keepSocketAlive(socket);
                free.push(socket);
                this._watchIdle(socket, name);
                return;
            }
        }
        socket.destroy();
        this._dispatch(name);
    };
    Agent.prototype.forgetSocket = function (socket, name) {
        if (!name) return;
        var active = this.sockets[name];
        if (active) {
            var ai = active.indexOf(socket);
            if (ai >= 0) active.splice(ai, 1);
        }
        this._clearIdle(socket);
    };
    Agent.prototype.removeRequest = function (req) {
        for (var name in this.requests) {
            var queue = this.requests[name] || [];
            for (var i = 0; i < queue.length; i++) {
                if (queue[i].req === req) { queue.splice(i, 1); return; }
            }
        }
    };
    Agent.prototype.createConnection = function (options) {
        var o = options || this.options || {};
        var protocol = o.protocol || this.protocol;
        if (protocol === 'https:') {
            return tlsModule.connect({
                port: o.port,
                host: o.hostname || o.host,
                servername: o.servername || o.hostname || o.host,
                rejectUnauthorized: o.rejectUnauthorized !== false,
                ca: o.ca, caFile: o.caFile,
                cert: o.cert, certFile: o.certFile,
                key: o.key, keyFile: o.keyFile,
                alpn: o.alpn
            });
        }
        return netModule.connect(o.port || this.defaultPort, o.hostname || o.host);
    };
    Agent.prototype.destroy = function () {
        var self = this;
        this._destroying = true;
        for (var k in this.sockets) {
            var active = (this.sockets[k] || []).slice();
            for (var i = 0; i < active.length; i++) {
                var s = active[i];
                if (!s) continue;
                self._clearIdle(s);
                if (typeof s.destroy === 'function') s.destroy();
            }
        }
        for (var f in this.freeSockets) {
            var free = (this.freeSockets[f] || []).slice();
            for (var j = 0; j < free.length; j++) {
                var fs = free[j];
                if (!fs) continue;
                self._clearIdle(fs);
                if (typeof fs.destroy === 'function') fs.destroy();
            }
        }
        for (var r in this.requests) {
            var queue = this.requests[r] || [];
            while (queue.length) {
                var entry = queue.shift();
                var err = new Error('agent destroyed');
                err.code = 'ERR_AGENT_DESTROYED';
                try { if (entry.req) entry.req.emit('error', err); } catch (e) { /* no listener */ }
            }
        }
        this.sockets = {};
        this.freeSockets = {};
        this.requests = {};
        this._destroying = false;
    };
    Agent.prototype.keepSocketAlive = function (socket) {
        if (typeof socket.setKeepAlive === 'function') socket.setKeepAlive(true, this.keepAliveMsecs);
        if (typeof socket.setTimeout === 'function') socket.setTimeout(0);
        return true;
    };
    Agent.prototype.reuseSocket = function (socket, options) {
        if (typeof socket.ref === 'function') socket.ref();
        if (typeof socket.setTimeout === 'function') socket.setTimeout(0);
        if (typeof socket.setNoDelay === 'function') socket.setNoDelay(true);
        return socket;
    };

    var STATUS_CODES = {
        100: 'Continue', 101: 'Switching Protocols', 102: 'Processing', 103: 'Early Hints',
        200: 'OK', 201: 'Created', 202: 'Accepted', 203: 'Non-Authoritative Information',
        204: 'No Content', 205: 'Reset Content', 206: 'Partial Content', 207: 'Multi-Status',
        208: 'Already Reported', 226: 'IM Used',
        300: 'Multiple Choices', 301: 'Moved Permanently', 302: 'Found', 303: 'See Other',
        304: 'Not Modified', 305: 'Use Proxy', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
        400: 'Bad Request', 401: 'Unauthorized', 402: 'Payment Required', 403: 'Forbidden',
        404: 'Not Found', 405: 'Method Not Allowed', 406: 'Not Acceptable',
        407: 'Proxy Authentication Required', 408: 'Request Timeout', 409: 'Conflict',
        410: 'Gone', 411: 'Length Required', 412: 'Precondition Failed', 413: 'Payload Too Large',
        414: 'URI Too Long', 415: 'Unsupported Media Type', 416: 'Range Not Satisfiable',
        417: 'Expectation Failed', 418: "I'm a Teapot", 421: 'Misdirected Request',
        422: 'Unprocessable Entity', 423: 'Locked', 424: 'Failed Dependency', 425: 'Too Early',
        426: 'Upgrade Required', 428: 'Precondition Required', 429: 'Too Many Requests',
        431: 'Request Header Fields Too Large', 451: 'Unavailable For Legal Reasons',
        500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway',
        503: 'Service Unavailable', 504: 'Gateway Timeout', 505: 'HTTP Version Not Supported',
        506: 'Variant Also Negotiates', 507: 'Insufficient Storage', 508: 'Loop Detected',
        509: 'Bandwidth Limit Exceeded', 510: 'Not Extended', 511: 'Network Authentication Required'
    };
    var METHODS = ['ACL', 'BIND', 'CHECKOUT', 'CONNECT', 'COPY', 'DELETE', 'GET', 'HEAD',
        'LINK', 'LOCK', 'M-SEARCH', 'MERGE', 'MKACTIVITY', 'MKCALENDAR', 'MKCOL', 'MOVE',
        'NOTIFY', 'OPTIONS', 'PATCH', 'POST', 'PROPFIND', 'PROPPATCH', 'PURGE', 'PUT',
        'REBIND', 'REPORT', 'SEARCH', 'SOURCE', 'SUBSCRIBE', 'TRACE', 'UNBIND', 'UNLINK',
        'UNLOCK', 'UNSUBSCRIBE'];

    var globalAgent = new Agent({
        protocol: 'http:', defaultPort: 80,
        keepAlive: true, keepAliveMsecs: 4000, maxSockets: 128
    });
    function defaultAgentFor(options) {
        if (options && options.protocol === 'https:' &&
            typeof httpsModule !== 'undefined' && httpsModule.globalAgent)
            return httpsModule.globalAgent;
        return globalAgent;
    }
    var httpModule = {
        request: request,
        get: get,
        ClientRequest: ClientRequest,
        IncomingMessage: IncomingMessage,
        ServerResponse: ServerResponse,
        Agent: Agent,
        globalAgent: globalAgent,
        STATUS_CODES: STATUS_CODES,
        METHODS: METHODS,
        maxHeaderSize: 16384,
        validateHeaderName: function (name) { checkHeader(name, ''); },
        validateHeaderValue: function (name, value) { checkHeader(name, value); }
    };

// ---- http.Server --------------------------------------------------
    function ServerResponse(socket, req, conn) {
        EventEmitter.call(this);
        this.socket = socket;
        this.req = req;
        this._conn = conn || null;
        this._keepAlive = !!(conn && conn.keepAlive);
        this._head = req.method === 'HEAD';
        this.statusCode = 200;
        this.statusMessage = 'OK';
        this._headers = {};
        this._chunked = false;
        this._headSent = false;
        this._ended = false;
        this.finished = false;
        this.writable = true;
        this.writableEnded = false;
    }
    ServerResponse.prototype = Object.create(EventEmitter.prototype);
    ServerResponse.prototype.constructor = ServerResponse;
    ServerResponse.prototype.setHeader = function (name, value) {
        // Server response headers are attacker-reachable through reflected
        // input; validate exactly like the client path so CRLF cannot enter
        // the status block (response splitting over keep-alive pipelines).
        if (Array.isArray(value)) {
            for (var vi = 0; vi < value.length; vi++) checkHeader(name, value[vi]);
        } else {
            checkHeader(name, value);
        }
        this._headers[String(name).toLowerCase()] = value;
        return this;
    };
    ServerResponse.prototype.getHeader = function (name) {
        return this._headers[String(name).toLowerCase()];
    };
    ServerResponse.prototype.removeHeader = function (name) {
        delete this._headers[String(name).toLowerCase()];
    };
    ServerResponse.prototype.getHeaders = function () {
        var out = {};
        for (var k in this._headers) out[k] = this._headers[k];
        return out;
    };
    ServerResponse.prototype.getHeaderNames = function () {
        return Object.keys(this._headers);
    };
    ServerResponse.prototype.getRawHeaderNames = function () {
        return Object.keys(this._headers);
    };
    ServerResponse.prototype.hasHeader = function (name) {
        return this._headers[String(name).toLowerCase()] !== undefined;
    };
    ServerResponse.prototype.appendHeader = function (name, value) {
        checkHeader(name, value);
        var key = String(name).toLowerCase();
        var current = this._headers[key];
        if (current === undefined) this._headers[key] = value;
        else if (Array.isArray(current)) current.push(value);
        else this._headers[key] = [current, value];
        return this;
    };
    ServerResponse.prototype.flushHeaders = function () { this._sendHead(); };
    ServerResponse.prototype.writeContinue = function () {
        if (this._headSent) return;
        this.socket.write(Buffer.from('HTTP/1.1 100 Continue\r\n\r\n', 'utf8'));
    };
    ServerResponse.prototype.writeEarlyHints = function (hints) {
        if (this._headSent) return;
        var head = 'HTTP/1.1 103 Early Hints\r\n';
        if (hints) {
            for (var k in hints) {
                var v = hints[k];
                if (Array.isArray(v)) { for (var i = 0; i < v.length; i++) head += k + ': ' + checkHeader(k, v[i]) + '\r\n'; }
                else head += k + ': ' + checkHeader(k, v) + '\r\n';
            }
        }
        this.socket.write(Buffer.from(head + '\r\n', 'utf8'));
    };
    Object.defineProperty(ServerResponse.prototype, 'headersSent', {
        get: function () { return this._headSent; },
        enumerable: true,
        configurable: true
    });
    ServerResponse.prototype.writeHead = function (status, message, headers) {
        if (typeof message === 'object' && message !== null) { headers = message; message = undefined; }
        status = Number(status);
        if (!(status >= 100 && status <= 999)) {
            var se = new Error('invalid status code: ' + status); se.code = 'ERR_HTTP_INVALID_STATUS_CODE'; throw se;
        }
        if (message !== undefined && message !== null && /[\r\n\0]/.test(String(message))) {
            var me = new Error('invalid characters in status message'); me.code = 'ERR_INVALID_CHAR'; throw me;
        }
        this.statusCode = status;
        if (message) this.statusMessage = message;
        if (headers) for (var k in headers) this.setHeader(k, headers[k]);
        return this;
    };
    ServerResponse.prototype._sendHead = function () {
        if (this._headSent) return;
        var hasLen = this._headers['content-length'] !== undefined;
        var hasTe = this._headers['transfer-encoding'] !== undefined;
        this._chunked = !hasLen && !hasTe;
        if (this._chunked) this._headers['transfer-encoding'] = 'chunked';
        this._headers['connection'] = this._headers['connection'] || (this._keepAlive ? 'keep-alive' : 'close');
        if (this._keepAlive && this._headers['keep-alive'] === undefined)
            this._headers['keep-alive'] = 'timeout=' + Math.floor((this._conn ? this._conn.server.keepAliveTimeout : 5000) / 1000);
        // The status message reached us through a constructor or writeHead;
        // belt-and-braces against any stored CRLF before it hits the wire.
        var statusText = String(this.statusMessage || '');
        if (/[\r\n\0]/.test(statusText)) statusText = statusText.replace(/[\r\n\0]/g, ' ');
        var head = 'HTTP/1.1 ' + this.statusCode + ' ' + statusText + '\r\n';
        for (var k in this._headers) {
            var hv = this._headers[k];
            if (Array.isArray(hv)) {
                for (var hi = 0; hi < hv.length; hi++) head += k + ': ' + checkHeader(k, hv[hi]) + '\r\n';
            } else {
                head += k + ': ' + checkHeader(k, hv) + '\r\n';
            }
        }
        head += '\r\n';
        this.socket.write(Buffer.from(head, 'utf8'));
        this._headSent = true;
    };
    ServerResponse.prototype.write = function (chunk) {
        if (this._ended) return false;
        var b = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
        if (!this._headSent && this._headers['content-length'] === undefined && this._headers['transfer-encoding'] === undefined) {
            // First write without a declared length: stream as chunked.
        }
        this._sendHead();
        if (this._head) return true;
        if (this._chunked) {
            this.socket.write(Buffer.from(b.length.toString(16) + '\r\n', 'utf8'));
            this.socket.write(b);
            this.socket.write(Buffer.from('\r\n', 'utf8'));
        } else {
            // Framing integrity: once a content-length was declared, the
            // body must not overrun it — extra bytes desync keep-alive
            // pipelines (the next response is parsed as this body).
            this._sent = (this._sent || 0) + b.length;
            var declared = Number(this._headers['content-length']);
            if (!this._chunked && this._headers['content-length'] !== undefined &&
                this._sent > declared) {
                this.destroy();
                return false;
            }
            this.socket.write(b);
        }
        return true;
    };
    ServerResponse.prototype.end = function (chunk) {
        if (this._ended) return;
        this._ended = true;
        var b = chunk === undefined ? null : (typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
        if (!this._headSent) {
            var body = b || Buffer.alloc(0);
            // Only size the response automatically when the app did not
            // frame it itself: a user-set transfer-encoding must not gain a
            // conflicting content-length.
            if (this._headers['transfer-encoding'] === undefined)
                this._headers['content-length'] = String(body.length);
            this._sendHead();
            if (body.length && !this._head) { this._sent = (this._sent || 0) + body.length; this.socket.write(body); }
        } else {
            if (b && b.length) this.write(b);
            if (this._chunked && !this._head) this.socket.write(Buffer.from('0\r\n\r\n', 'utf8'));
        }
        // A declared content-length that was not matched is a framing error:
        // silently sending fewer bytes hangs the peer mid-pipeline. HEAD
        // responses never write the body, so the check does not apply.
        if (!this._head && !this._chunked && this._headers['content-length'] !== undefined &&
            (this._sent || 0) !== Number(this._headers['content-length'])) {
            var e = new Error('response content-length mismatch');
            e.code = 'ERR_HTTP_CONTENT_LENGTH_MISMATCH';
            this.emit('error', e);
            this.destroy();
            return;
        }
        this.finished = true;
        this.writableEnded = true;
        this.writable = false;
        this.emit('finish');
        if (this._conn) {
            if (this._keepAlive && this._conn.server.listening) this._conn._responseDone(this);
            else { this.socket.end(); this._conn._responseDone(this); }
        } else if (!this._keepAlive) {
            this.socket.end();
        }
    };

    function HttpServer(opts, handler) {
        EventEmitter.call(this);
        if (typeof opts === 'function') { handler = opts; opts = {}; }
        if (handler) this.on('request', handler);
        this.listening = false;
        this.keepAliveTimeout = 5000;
        this.headersTimeout = 60000;
        this.requestTimeout = 300000;
        this.maxHeaderSize = 16384;
        this._connections = new Set();
        this._net = (opts && (opts.cert || opts.key)) ? new TlsServer(opts) : new Server();
        var self = this;
        this._net.on('connection', function (socket) { self._accept(socket); });
    }
    HttpServer.prototype = Object.create(EventEmitter.prototype);
    HttpServer.prototype.constructor = HttpServer;
    HttpServer.prototype.listen = function (port, host, cb) {
        var self = this;
        this._net.listen(port, host, function () {
            self.listening = true;
            self.emit('listening');
            if (cb) cb();
        });
        return this;
    };
    HttpServer.prototype.address = function () { return this._net.address(); };
    HttpServer.prototype.close = function (cb) {
        this.listening = false;
        var pending = this._connections.size;
        this._pendingClose = cb || null;
        if (pending === 0) {
            this._pendingClose = null;
            this._net.close(cb);
            return this;
        }
        this._net.close();
        for (var conn of Array.from(this._connections)) {
            if (!conn.busy) conn.destroy();
        }
        return this;
    };
    HttpServer.prototype.closeAllConnections = function () {
        for (var conn of Array.from(this._connections)) conn.destroy();
    };
    HttpServer.prototype.closeIdleConnections = function () {
        for (var conn of Array.from(this._connections)) if (!conn.busy) conn.destroy();
    };
    function HttpConnection(server, socket) {
        this.server = server;
        this.socket = socket;
        this.buffer = Buffer.alloc(0);
        this.state = 'head';
        this.cur = null;
        this.busy = false;
        this.closed = false;
        this.keepAlive = true;
        this._pumping = false;
        var self = this;
        socket.on('data', function (chunk) { self._onData(chunk); });
        socket.on('error', function (e) { self.server.emit('clientError', e, socket); self.destroy(); });
        socket.on('close', function () { self._cleanup(); });
        socket.on('timeout', function () { self.destroy(); });
        socket.setTimeout(server.headersTimeout);
        server._connections.add(this);
    }
    HttpConnection.prototype._consume = function (n) {
        this.buffer = n >= this.buffer.length ? Buffer.alloc(0) : this.buffer.slice(n);
    };
    HttpConnection.prototype._arm = function (ms) { this.socket.setTimeout(ms); };
    HttpConnection.prototype._onData = function (chunk) {
        if (this.closed || this.upgraded) return;
        this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
        // While a handler runs, pipelined bytes have nowhere to go; bound
        // them so a pipelining client cannot grow memory without limit.
        if (this.state === 'waiting' && this.buffer.length > 1024 * 1024) {
            this.destroy();
            return;
        }
        this._pump();
    };
    HttpConnection.prototype._pump = function () {
        if (this._pumping) return;
        this._pumping = true;
        try {
            while (!this.closed) {
                if (this.state === 'waiting') break;
                if (this.state === 'head') {
                    if (this.buffer.length === 0) break;
                    var text = this.buffer.toString('latin1');
                    var idx = text.indexOf('\r\n\r\n');
                    if (idx < 0) {
                        if (this.buffer.length > this.server.maxHeaderSize) this.destroy();
                        break;
                    }
                    if (idx > this.server.maxHeaderSize) { this.destroy(); break; }
                    var head = this.buffer.slice(0, idx).toString('utf8');
                    var rest = this.buffer.slice(idx + 4);
                    this.buffer = rest;
                    var lines = head.split('\r\n');
                    var first = (lines.shift() || '').split(' ');
                    if (first.length < 2) { this.destroy(); break; }
                    var headers = {};
                    for (var i = 0; i < lines.length; i++) {
                        var c = lines[i].indexOf(':');
                        if (c <= 0) continue;
                        var hn = lines[i].slice(0, c).trim().toLowerCase();
                        var hv = lines[i].slice(c + 1).trim();
                        headers[hn] = headers[hn] === undefined ? hv : headers[hn] + ', ' + hv;
                    }
                    var version = (first[2] || 'HTTP/1.1').replace('HTTP/', '');
                    var connHeader = String(headers['connection'] || '').toLowerCase();
                    this.keepAlive = version === '1.0' ? connHeader === 'keep-alive' : connHeader !== 'close';
                    var req = new IncomingMessage(Number(first[1]), first.slice(2).join(' '), headers);
                    req.method = first[0];
                    req.url = first[1];
                    req.httpVersion = version;
                    req.socket = this.socket;
                    req.connection = this.socket;
                    req.complete = false;
                    if (connHeader.indexOf('upgrade') !== -1 && headers.upgrade) {
                        var head = this.buffer;
                        this.buffer = Buffer.alloc(0);
                        this.state = 'upgrade';
                        this.upgraded = true;
                        this.busy = true;
                        this.server._connections.delete(this);
                        this._maybeClose();
                        this.socket.setTimeout(0);
                        var handled = this.server.emit('upgrade', req, this.socket, head);
                        if (!handled) this.destroy();
                        break;
                    }
                    var clen = Number(headers['content-length'] || 0);
                    if (!(clen >= 0) || clen > 8 * 1024 * 1024) { this.destroy(); break; }
                    // Transfer-Encoding + Content-Length is the classic
                    // request-smuggling ambiguity behind a CL-preferring
                    // front end; reject it like llhttp/Node.
                    if (headers['transfer-encoding'] !== undefined && headers['content-length'] !== undefined) {
                        this.destroy(); break;
                    }
                    // "chunked" must be the final transfer coding, not a
                    // substring of some other coding name.
                    var teList = String(headers['transfer-encoding'] || '').toLowerCase().split(',').map(function (s) { return s.trim(); });
                    var chunked = teList[teList.length - 1] === 'chunked';
                    if (headers['transfer-encoding'] !== undefined && !chunked) { this.destroy(); break; }
                    this.cur = { req: req, chunks: [], total: 0, remaining: clen, chunked: chunked };
                    if (String(headers['expect'] || '').toLowerCase() === '100-continue')
                        this.socket.write(Buffer.from('HTTP/1.1 100 Continue\r\n\r\n', 'utf8'));
                    if (chunked) { this.state = 'chunk-size'; this._arm(this.server.requestTimeout); }
                    else if (clen > 0) { this.state = 'fixed'; this._arm(this.server.requestTimeout); }
                    else { this._dispatch(); }
                    continue;
                }
                if (this.state === 'fixed') {
                    if (this.buffer.length === 0) break;
                    var take = Math.min(this.cur.remaining, this.buffer.length);
                    this.cur.chunks.push(this.buffer.slice(0, take));
                    this.cur.total += take;
                    this.cur.remaining -= take;
                    this._consume(take);
                    if (this.cur.remaining === 0) this._dispatch();
                    continue;
                }
                if (this.state === 'chunk-size') {
                    var eol = this.buffer.toString('latin1').indexOf('\r\n');
                    if (eol < 0) { if (this.buffer.length > 1024) this.destroy(); break; }
                    var sizeLine = this.buffer.slice(0, eol).toString('latin1').split(';')[0].trim();
                    this._consume(eol + 2);
                    var size = parseInt(sizeLine, 16);
                    if (!(size >= 0)) { this.destroy(); break; }
                    if (size === 0) { this.state = 'trailers'; continue; }
                    if (this.cur.total + size > 8 * 1024 * 1024) { this.destroy(); break; }
                    this.cur.chunkRemaining = size;
                    this.state = 'chunk-data';
                    continue;
                }
                if (this.state === 'chunk-data') {
                    if (this.buffer.length === 0) break;
                    var t = Math.min(this.cur.chunkRemaining, this.buffer.length);
                    this.cur.chunks.push(this.buffer.slice(0, t));
                    this.cur.total += t;
                    this.cur.chunkRemaining -= t;
                    this._consume(t);
                    if (this.cur.chunkRemaining === 0) this.state = 'chunk-crlf';
                    continue;
                }
                if (this.state === 'chunk-crlf') {
                    if (this.buffer.length < 2) break;
                    if (this.buffer[0] !== 13 || this.buffer[1] !== 10) { this.destroy(); break; }
                    this._consume(2);
                    this.state = 'chunk-size';
                    continue;
                }
                if (this.state === 'trailers') {
                    var endIdx = this.buffer.toString('latin1').indexOf('\r\n');
                    if (endIdx < 0) break;
                    this._consume(endIdx + 2);
                    this._dispatch();
                    continue;
                }
                break;
            }
        } finally {
            this._pumping = false;
        }
    };
    HttpConnection.prototype._dispatch = function () {
        var cur = this.cur;
        var req = cur.req;
        var res = new ServerResponse(this.socket, req, this);
        this.state = 'waiting';
        this.busy = true;
        this._arm(this.server.requestTimeout);
        req.complete = true;
        this.server.emit('request', req, res);
        var body = cur.chunks.length ? Buffer.concat(cur.chunks) : Buffer.alloc(0);
        req.push(body);
        req.push(null);
    };
    HttpConnection.prototype._responseDone = function () {
        this.busy = false;
        if (this.closed) return;
        if (!this.server.listening || !this.keepAlive) {
            this.socket.end();
            return;
        }
        this.state = 'head';
        this.cur = null;
        this._arm(this.server.keepAliveTimeout);
        this._pump();
    };
    HttpConnection.prototype.destroy = function (err) {
        if (this.closed) return;
        this.closed = true;
        this.server._connections.delete(this);
        this.socket.destroy(err);
        this._maybeClose();
    };
    HttpConnection.prototype._cleanup = function () {
        if (!this.closed) {
            this.closed = true;
            this.server._connections.delete(this);
        }
        this._maybeClose();
    };
    HttpConnection.prototype._maybeClose = function () {
        var server = this.server;
        if (server._pendingClose && server._connections.size === 0) {
            var cb = server._pendingClose;
            server._pendingClose = null;
            cb();
        }
    };

    HttpServer.prototype._accept = function (socket) {
        var conn = new HttpConnection(this, socket);
        this.emit('connection', socket);
        return conn;
    };

    httpModule.ServerResponse = ServerResponse;
    httpModule.Server = HttpServer;
    httpModule.createServer = function (opts, handler) {
        return new HttpServer(opts, handler);
    };

    // ---- readline -----------------------------------------------------
    function readlineStream(stream) {
        if (stream && typeof stream.write === 'function') return stream;
        return g.process && g.process.stdout ? g.process.stdout : null;
    }
    function readlineWrite(stream, text) {
        var s = readlineStream(stream);
        if (!s) return false;
        s.write(text);
        return true;
    }
    var readlineModule = {
        cursorTo: function (stream, x, y) {
            var seq = '\x1b[' + (Math.max(0, Number(y) || 0) + 1) + ';' + (Math.max(0, Number(x) || 0) + 1) + 'H';
            return readlineWrite(stream, seq);
        },
        moveCursor: function (stream, dx, dy) {
            var seq = '';
            var x = Number(dx) || 0, y = Number(dy) || 0;
            if (x < 0) seq += '\x1b[' + (-x) + 'D';
            else if (x > 0) seq += '\x1b[' + x + 'C';
            if (y < 0) seq += '\x1b[' + (-y) + 'A';
            else if (y > 0) seq += '\x1b[' + y + 'B';
            return readlineWrite(stream, seq);
        },
        clearLine: function (stream, dir) {
            var code = dir === -1 ? 1 : (dir === 1 ? 0 : 2);
            return readlineWrite(stream, '\x1b[' + code + 'K');
        },
        clearScreenDown: function (stream) {
            return readlineWrite(stream, '\x1b[0J');
        },
        createInterface: function (opts) {
            EventEmitter.call(this);
            var input = opts && opts.input ? opts.input : processObj.stdin;
            var output = opts && opts.output ? opts.output : null;
            var self = new EventEmitter();
            var buffer = '';
            var closed = false;
            var waiting = [];
            function emitLine(line) {
                if (waiting.length) waiting.shift()(line);
                else self.emit('line', line);
            }
            input.on('data', function (chunk) {
                buffer += chunk.toString();
                var idx;
                while ((idx = buffer.indexOf('\n')) >= 0) {
                    var line = buffer.slice(0, idx);
                    if (line.endsWith('\r')) line = line.slice(0, -1);
                    buffer = buffer.slice(idx + 1);
                    emitLine(line);
                }
            });
            input.on('end', function () {
                if (buffer.length) { emitLine(buffer); buffer = ''; }
                closed = true;
                self.emit('close');
            });
            self.question = function (prompt, cb) {
                if (output) output.write(prompt);
                waiting.push(cb);
            };
            self.close = function () { if (!closed) { closed = true; self.emit('close'); } };
            self.pause = function () { input.pause(); return self; };
            self.resume = function () { input.resume(); return self; };
            return self;
        }
    };
    g.readline = readlineModule;
    g.readlinePromises = {
        createInterface: function (opts) {
            var iface = readlineModule.createInterface(opts);
            var lines = [], waiters = [], closed = false;
            iface.on('line', function (line) {
                if (waiters.length) waiters.shift()(line);
                else lines.push(line);
            });
            iface.on('close', function () {
                closed = true;
                while (waiters.length) waiters.shift()(null);
            });
            var baseQuestion = iface.question;
            iface.question = function (prompt) {
                return new Promise(function (resolve) { baseQuestion.call(iface, prompt, resolve); });
            };
            iface[Symbol.asyncIterator] = function () {
                return {
                    next: function () {
                        if (lines.length) return Promise.resolve({ value: lines.shift(), done: false });
                        if (closed) return Promise.resolve({ value: undefined, done: true });
                        return new Promise(function (resolve) {
                            waiters.push(function (line) {
                                if (line === null) resolve({ value: undefined, done: true });
                                else resolve({ value: line, done: false });
                            });
                        });
                    }
                };
            };
            return iface;
        }
    };

    function DgramSocket(opts) {
        EventEmitter.call(this);
        this._id = __djs.dgram.create();
        this._bound = false;
        this.type = (opts && opts.type) || 'udp4';
    }
    DgramSocket.prototype = Object.create(EventEmitter.prototype);
    DgramSocket.prototype.constructor = DgramSocket;
    DgramSocket.prototype.bind = function (port, host, cb) {
        if (typeof port === 'object' && port !== null) { host = port.address; port = port.port; }
        if (typeof host === 'function') { cb = host; host = '0.0.0.0'; }
        var bindHost = (!host || host === 'localhost') ? '0.0.0.0' : String(host);
        var p = __djs.dgram.bind(this._id, bindHost, Number(port) || 0);
        this._bound = true;
        this.port = p;
        var self = this;
        __djs.dgram.startRecv(this._id, function (err, data, rinfo) {
            if (err) { self.emit('error', err); return; }
            self.emit('message', Buffer.from(data), rinfo);
        });
        queueMicrotask(function () { self.emit('listening'); if (cb) cb(); });
        return this;
    };
    DgramSocket.prototype.send = function (msg, port, host, cb) {
        if (typeof host === 'function') { cb = host; host = '127.0.0.1'; }
        var b = typeof msg === 'string' ? Buffer.from(msg) : msg;
        var target = (!host || host === 'localhost') ? '127.0.0.1' : String(host);
        var n = __djs.dgram.send(this._id, target, Number(port), b);
        if (cb) queueMicrotask(function () { cb(null, n); });
        return this;
    };
    DgramSocket.prototype.address = function () { return __djs.dgram.address(this._id); };
    DgramSocket.prototype.setBroadcast = function (flag) { __djs.dgram.setBroadcast(this._id, !!flag); return this; };
    DgramSocket.prototype.setTTL = function (ttl) { __djs.dgram.setTTL(this._id, Number(ttl)); return this; };
    DgramSocket.prototype.setMulticastTTL = function (ttl) { __djs.dgram.setMulticastTTL(this._id, Number(ttl)); return this; };
    DgramSocket.prototype.addMembership = function (addr, iface) { __djs.dgram.addMembership(this._id, String(addr)); return this; };
    DgramSocket.prototype.dropMembership = function (addr, iface) { __djs.dgram.dropMembership(this._id, String(addr)); return this; };
    DgramSocket.prototype.close = function (cb) {
        if (this._id) { __djs.dgram.close(this._id); this._id = 0; }
        queueMicrotask(function () { if (cb) cb(); });
    };

    function utf8CompleteLength(b) {
        var i = b.length - 1;
        while (i >= 0 && (b[i] & 0xC0) === 0x80) i--;
        if (i < 0) return b.length;
        var lead = b[i], need = 1;
        if ((lead & 0xE0) === 0xC0) need = 2;
        else if ((lead & 0xF0) === 0xE0) need = 3;
        else if ((lead & 0xF8) === 0xF0) need = 4;
        return (b.length - i >= need) ? b.length : i;
    }
    function StringDecoder(encoding) {
        this.encoding = String(encoding || 'utf8').toLowerCase().replace(/[-_]/g, '');
        this._pending = null;
    }
    StringDecoder.prototype.write = function (buf) {
        if (typeof buf === 'string') return buf;
        var data = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
        if (this.encoding !== 'utf8') {
            return data.toString(this.encoding === 'ucs2' ? 'utf16le' : this.encoding);
        }
        var all = this._pending ? Buffer.concat([this._pending, data]) : data;
        var cut = utf8CompleteLength(all);
        this._pending = cut < all.length ? Buffer.from(all.subarray(cut)) : null;
        return all.subarray(0, cut).toString('utf8');
    };
    StringDecoder.prototype.end = function (buf) {
        if (this.encoding !== 'utf8') return buf ? this.write(buf) : '';
        var tail = buf ? (Buffer.isBuffer(buf) ? buf : Buffer.from(buf)) : null;
        var all = this._pending && tail ? Buffer.concat([this._pending, tail])
            : (this._pending || tail);
        this._pending = null;
        return all ? all.toString('utf8') : '';
    };
    g.string_decoder = { StringDecoder: StringDecoder };


    // ---- assert -------------------------------------------------------
    function assertInspect(v) {
        if (typeof v === 'string') return JSON.stringify(v);
        if (typeof v === 'function') return v.name ? '[Function: ' + v.name + ']' : '[Function]';
        if (v === undefined) return 'undefined';
        if (v === null) return 'null';
        if (typeof v === 'object') {
            try { return JSON.stringify(v); } catch (e) { return Object.prototype.toString.call(v); }
        }
        return String(v);
    }

    function AssertionError(options) {
        options = options || {};
        this.name = 'AssertionError';
        this.code = 'ERR_ASSERTION';
        this.actual = options.actual;
        this.expected = options.expected;
        this.operator = options.operator || '==';
        this.generatedMessage = options.message === undefined;
        var msg = options.message;
        if (msg === undefined) {
            msg = 'Expected values to be ' + (this.operator === 'strictEqual' ? 'strictly equal' : 'equal') +
                ':\n\n  actual: ' + assertInspect(this.actual) +
                '\nexpected: ' + assertInspect(this.expected);
        }
        this.message = String(msg);
        if (Error.captureStackTrace) Error.captureStackTrace(this, AssertionError);
        else this.stack = new Error(this.message).stack;
    }
    AssertionError.prototype = Object.create(Error.prototype);
    AssertionError.prototype.constructor = AssertionError;

    function assertFail(message) {
        throw new AssertionError({ message: message === undefined ? 'Failed' : message, operator: 'fail' });
    }
    function assertCompare(actual, expected, operator, message) {
        throw new AssertionError({ actual: actual, expected: expected, operator: operator, message: message });
    }

    function assertObjectLike(v) { return v !== null && typeof v === 'object'; }
    function assertTag(v) { return Object.prototype.toString.call(v); }
    function assertBytes(v) {
        if (Buffer.isBuffer(v)) return v;
        if (ArrayBuffer.isView(v)) return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
        if (assertTag(v) === '[object ArrayBuffer]') return Buffer.from(v);
        return null;
    }
    function assertKeys(v) {
        var ks = Object.keys(v);
        if (Object.getOwnPropertySymbols) {
            var syms = Object.getOwnPropertySymbols(v);
            for (var i = 0; i < syms.length; i++)
                if (Object.prototype.propertyIsEnumerable.call(v, syms[i])) ks.push(syms[i]);
        }
        return ks;
    }
    function assertDeepEqual(a, b, strict, seenA, seenB) {
        if (strict ? Object.is(a, b) : (a == b || (a !== a && b !== b))) return true;
        if (!assertObjectLike(a) || !assertObjectLike(b)) return false;
        var idx = seenA.indexOf(a);
        if (idx !== -1) return seenB[idx] === b;
        seenA.push(a); seenB.push(b);
        var ta = assertTag(a), tb = assertTag(b);
        if (ta !== tb) return false;
        if (ta === '[object Date]') return a.getTime() === b.getTime();
        if (ta === '[object RegExp]') return a.source === b.source && a.flags === b.flags;
        if (a instanceof Error || b instanceof Error) return a.name === b.name && a.message === b.message;
        var ba = assertBytes(a), bb = assertBytes(b);
        if (ba && bb) return ba.length === bb.length && Buffer.compare(ba, bb) === 0;
        if (ta === '[object Map]') {
            if (a.size !== b.size) return false;
            var mapOk = true;
            a.forEach(function (v, k) {
                if (!mapOk) return;
                var found = false, match = false;
                b.forEach(function (bv, bk) {
                    if (found) return;
                    if (assertDeepEqual(k, bk, strict, seenA.slice(), seenB.slice())) {
                        found = true;
                        match = assertDeepEqual(v, bv, strict, seenA.slice(), seenB.slice());
                    }
                });
                if (!found || !match) mapOk = false;
            });
            return mapOk;
        }
        if (ta === '[object Set]') {
            if (a.size !== b.size) return false;
            var setOk = true;
            a.forEach(function (v) {
                if (!setOk) return;
                var found = false;
                b.forEach(function (bv) {
                    if (!found && assertDeepEqual(v, bv, strict, seenA.slice(), seenB.slice())) found = true;
                });
                if (!found) setOk = false;
            });
            return setOk;
        }
        if (Array.isArray(a)) {
            if (a.length !== b.length) return false;
            for (var i = 0; i < a.length; i++)
                if (!assertDeepEqual(a[i], b[i], strict, seenA, seenB)) return false;
        }
        if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
        var ka = assertKeys(a), kb = assertKeys(b);
        if (ka.length !== kb.length) return false;
        for (var j = 0; j < ka.length; j++) {
            var key = ka[j];
            if (!Object.prototype.propertyIsEnumerable.call(b, key)) return false;
            if (!assertDeepEqual(a[key], b[key], strict, seenA, seenB)) return false;
        }
        return true;
    }

    function assertErrorMatch(err, expected) {
        if (expected === undefined) return true;
        if (typeof expected === 'function') {
            var isClass = expected === Error || expected.prototype instanceof Error ||
                (expected.prototype && expected.prototype.name === 'Error') || /Error$/.test(expected.name);
            if (isClass) return err instanceof expected;
            return expected(err) === true;
        }
        if (expected instanceof RegExp) return expected.test(String(err && err.message));
        if (expected && typeof expected === 'object') {
            for (var k in expected) if (err[k] !== expected[k]) return false;
            return true;
        }
        return false;
    }

    function assertThrows(fn, expected, message) {
        if (typeof fn !== 'function') throw new TypeError('The "fn" argument must be of type function');
        var thrown = null, didThrow = false;
        try { fn(); } catch (e) { didThrow = true; thrown = e; }
        if (!didThrow) assertFail(message === undefined ? 'Missing expected exception.' : message);
        if (!assertErrorMatch(thrown, expected)) {
            assertFail(message === undefined
                ? 'The error thrown did not match the expectation: ' + (thrown && thrown.message)
                : message);
        }
        return thrown;
    }

    function assertRejects(fn, expected, message) {
        var promise = typeof fn === 'function' ? Promise.resolve().then(fn) : Promise.resolve(fn);
        return promise.then(function () {
            assertFail(message === undefined ? 'Missing expected rejection.' : message);
        }, function (err) {
            if (!assertErrorMatch(err, expected)) {
                assertFail(message === undefined
                    ? 'The rejection did not match the expectation: ' + (err && err.message)
                    : message);
            }
        });
    }

    function assert(value, message) {
        if (!value) assertCompare(value, true, '==', message);
    }
    assert.ok = assert;
    assert.fail = function (message) { assertFail(message); };
    assert.equal = function (a, b, m) { if (!(a == b)) assertCompare(a, b, '==', m); };
    assert.notEqual = function (a, b, m) { if (a == b) assertCompare(a, b, '!=', m); };
    assert.strictEqual = function (a, b, m) { if (!Object.is(a, b)) assertCompare(a, b, 'strictEqual', m); };
    assert.notStrictEqual = function (a, b, m) { if (Object.is(a, b)) assertCompare(a, b, 'notStrictEqual', m); };
    assert.deepEqual = function (a, b, m) {
        if (!assertDeepEqual(a, b, false, [], [])) assertCompare(a, b, 'deepEqual', m);
    };
    assert.notDeepEqual = function (a, b, m) {
        if (assertDeepEqual(a, b, false, [], [])) assertCompare(a, b, 'notDeepEqual', m);
    };
    assert.deepStrictEqual = function (a, b, m) {
        if (!assertDeepEqual(a, b, true, [], [])) assertCompare(a, b, 'deepStrictEqual', m);
    };
    assert.notDeepStrictEqual = function (a, b, m) {
        if (assertDeepEqual(a, b, true, [], [])) assertCompare(a, b, 'notDeepStrictEqual', m);
    };
    assert.throws = assertThrows;
    assert.doesNotThrow = function (fn, expected, message) {
        if (typeof fn !== 'function') throw new TypeError('The "fn" argument must be of type function');
        try { fn(); } catch (e) {
            if (expected !== undefined && !assertErrorMatch(e, expected)) { assertFail(message || 'Unexpected error.'); return; }
            assertFail(message === undefined ? 'Got unwanted exception: ' + (e && e.message) : message);
        }
    };
    assert.rejects = assertRejects;
    assert.doesNotReject = function (fn, expected, message) {
        var promise = typeof fn === 'function' ? Promise.resolve().then(fn) : Promise.resolve(fn);
        return promise.catch(function (e) {
            if (expected !== undefined && !assertErrorMatch(e, expected)) { assertFail(message || 'Unexpected rejection.'); return; }
            assertFail(message === undefined ? 'Got unwanted rejection: ' + (e && e.message) : message);
        });
    };
    assert.ifError = function (value) {
        if (value) {
            if (value instanceof Error) throw value;
            throw new AssertionError({ message: 'ifError got unwanted exception: ' + assertInspect(value), actual: value, expected: null, operator: 'ifError' });
        }
    };
    assert.match = function (string, regexp, message) {
        if (!(regexp instanceof RegExp)) throw new TypeError('The "regexp" argument must be an instance of RegExp');
        if (!regexp.test(String(string))) assertCompare(string, regexp, 'match', message);
    };
    assert.doesNotMatch = function (string, regexp, message) {
        if (!(regexp instanceof RegExp)) throw new TypeError('The "regexp" argument must be an instance of RegExp');
        if (regexp.test(String(string))) assertCompare(string, regexp, 'doesNotMatch', message);
    };
    assert.AssertionError = AssertionError;

    var assertStrict = function (value, message) { assert(value, message); };
    for (var assertKey in assert) assertStrict[assertKey] = assert[assertKey];
    assertStrict.equal = assert.strictEqual;
    assertStrict.notEqual = assert.notStrictEqual;
    assertStrict.deepEqual = assert.deepStrictEqual;
    assertStrict.notDeepEqual = assert.notDeepStrictEqual;
    assertStrict.strict = assertStrict;
    assert.strict = assertStrict;

