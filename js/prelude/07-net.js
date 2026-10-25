    // ---- TLS ----------------------------------------------------------
    function TlsSocket(opts) {
        Duplex.call(this);
        this._id = 0;
        this._reading = false;
        this.connecting = true;
        this.destroyed = false;
        this.authorized = false;
        this._tlsOpts = opts || {};
    }
    TlsSocket.prototype = Object.create(Duplex.prototype);
    TlsSocket.prototype.constructor = TlsSocket;
    TlsSocket.prototype._read = function () {
        if (!this._id || this.destroyed || this._reading) return;
        this._reading = true;
        var self = this;
        __djs.tls.startRead(this._id, function (err, data) {
            if (self.destroyed) return;
            self._armTimeout();
            if (err) { self.emit('error', err); self.destroy(); return; }
            if (data === null) { self.push(null); self.destroy(); return; }
            self.push(Buffer.from(data));
        });
    };
    TlsSocket.prototype._write = function (chunk, enc, cb) {
        if (!this._id || this.destroyed) {
            var e = new Error('TLS socket is not connected');
            e.code = 'ERR_TLS_CLOSED';
            cb(e);
            return;
        }
        this._armTimeout();
        __djs.tls.write(this._id, chunk, function (err) { cb(err || undefined); });
    };
    TlsSocket.prototype._final = function (cb) {
        if (this._id) __djs.tls.end(this._id);
        cb();
    };
    TlsSocket.prototype.destroy = function (err) {
        if (this.destroyed) return this;
        this.destroyed = true;
        if (this._timeoutTimer) { clearTimeout(this._timeoutTimer); this._timeoutTimer = null; }
        if (this._id) { __djs.tls.close(this._id); this._id = 0; }
        if (err) this.emit('error', err);
        this.emit('close');
        return this;
    };
    TlsSocket.prototype.setNoDelay = function () { return this; };
    // A real idle timer, re-armed on every read and write: HttpConnection
    // arms headersTimeout/requestTimeout through this, and a no-op here
    // meant a slowloris client could hold a TLS server socket forever.
    TlsSocket.prototype._armTimeout = function () {
        var self = this;
        if (this._timeoutTimer) { clearTimeout(this._timeoutTimer); this._timeoutTimer = null; }
        if (!this._timeoutMs || this.destroyed) return;
        this._timeoutTimer = setTimeout(function () {
            self._timeoutTimer = null;
            self.emit('timeout');
        }, this._timeoutMs);
        if (this._timeoutTimer && typeof this._timeoutTimer.unref === 'function')
            this._timeoutTimer.unref();
    };
    TlsSocket.prototype.setTimeout = function (ms, cb) {
        if (typeof cb === 'function') this.once('timeout', cb);
        this._timeoutMs = Number(ms) || 0;
        this._armTimeout();
        return this;
    };

    function tlsConnect(opts, cb) {
        if (typeof opts === 'number') opts = { port: opts, host: arguments[1] };
        opts = opts || {};
        var host = opts.host || opts.hostname || 'localhost';
        var s = new TlsSocket(opts);
        __djs.tls.connect(String(host), Number(opts.port),
            String(opts.servername || host), opts.rejectUnauthorized !== false,
            function (err, id) {
                if (err) {
                    s.connecting = false;
                    s.emit('error', err);
                    return;
                }
                s._id = id;
                s.connecting = false;
                s.authorized = true;
                s.alpnProtocol = __djs.tls.alpn(id);
                s.emit('connect');
                if (cb) cb();
                s._read();
            }, opts);
        return s;
    }

    function TlsServer(opts, listener) {
        EventEmitter.call(this);
        if (typeof opts === 'function') { listener = opts; opts = {}; }
        this._opts = opts || {};
        this._id = 0;
        this.port = 0;
        this.listening = false;
        if (listener) this.on('secureConnection', listener);
    }
    TlsServer.prototype = Object.create(EventEmitter.prototype);
    TlsServer.prototype.constructor = TlsServer;
    TlsServer.prototype.listen = function (port, host, cb) {
        if (typeof port === 'object' && port !== null) { var o = port; port = o.port; host = o.host || o.hostname; }
        if (typeof host === 'function') { cb = host; host = undefined; }
        var self = this;
        this._id = __djs.net.listen(host || '127.0.0.1', Number(port) || 0, function (connId) {
            var id;
            try {
                var fd = __djs.net.detachFd(connId);
                id = __djs.tls.acceptFd(fd, String(self._opts.cert), String(self._opts.key), self._opts);
            } catch (e) { self.emit('tlsClientError', e); return; }
            if (typeof id !== 'number') { self.emit('tlsClientError', id || new Error('TLS accept failed')); return; }
            var sock = new TlsSocket({});
            sock._id = id;
            sock.connecting = false;
            sock.encrypted = true;
            sock.authorized = __djs.tls.peerAuthorized(id);
            sock.alpnProtocol = __djs.tls.alpn(id);
            self.emit('secureConnection', sock);
            self.emit('connection', sock);
            sock._read();
        });
        this.port = __djs.net.listenerPort(this._id);
        this.listening = true;
        queueMicrotask(function () { self.emit('listening'); if (cb) cb(); });
        return this;
    };
    TlsServer.prototype.address = function () {
        return this.listening ? { address: '127.0.0.1', family: 'IPv4', port: this.port } : null;
    };
    TlsServer.prototype.close = function (cb) {
        if (this._id) { __djs.net.closeListener(this._id); this._id = 0; }
        this.listening = false;
        var self = this;
        queueMicrotask(function () { self.emit('close'); if (cb) cb(); });
        return this;
    };

    var tlsModule = {
        connect: tlsConnect,
        TLSSocket: TlsSocket,
        Server: TlsServer,
        createServer: function (opts, listener) { return new TlsServer(opts, listener); }
    };

    httpsModule.createServer = function (opts, handler) { return new HttpServer(opts || {}, handler); };
    httpsModule.Agent = httpModule.Agent;
    httpsModule.globalAgent = new httpModule.Agent({ protocol: 'https:', defaultPort: 443 });
    httpsModule.STATUS_CODES = httpModule.STATUS_CODES;
    httpsModule.METHODS = httpModule.METHODS;
    httpsModule.Server = HttpServer;

    g.net = netModule;
    g.tls = tlsModule;

    // ---- WebSocket (djs:ws) ------------------------------------------------
    var WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    function wsW32(buf, off, v) {
        buf[off] = Math.floor(v / 16777216) & 255;
        buf[off + 1] = (v >> 16) & 255;
        buf[off + 2] = (v >> 8) & 255;
        buf[off + 3] = v & 255;
    }

    function wsAccept(key) {
        return cryptoModule.createHash("sha1").update(key + WS_GUID).digest("base64");
    }

    function wsEncode(opcode, payload, mask) {
        payload = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload));
        var len = payload.length, header, i;
        if (len < 126) {
            header = Buffer.alloc(2);
            header[1] = len;
        } else if (len < 65536) {
            header = Buffer.alloc(4);
            header[1] = 126;
            header.writeUInt16BE(len, 2);
        } else {
            header = Buffer.alloc(10);
            header[1] = 127;
            wsW32(header, 2, Math.floor(len / 4294967296));
            wsW32(header, 6, len >>> 0);
        }
        header[0] = 0x80 | opcode;
        if (!mask) return Buffer.concat([header, payload]);
        header[1] |= 0x80;
        var key = cryptoModule.randomBytes(4);
        var body = Buffer.alloc(len);
        for (i = 0; i < len; i++) body[i] = payload[i] ^ key[i % 4];
        return Buffer.concat([header, key, body]);
    }

    function wsDecode(buf) {
        if (buf.length < 2) return null;
        var b0 = buf[0], b1 = buf[1];
        var opcode = b0 & 0x0f, masked = (b1 & 0x80) !== 0, len = b1 & 0x7f, off = 2;
        if (len === 126) {
            if (buf.length < 4) return null;
            len = buf.readUInt16BE(2); off = 4;
        } else if (len === 127) {
            if (buf.length < 10) return null;
            len = buf.readUInt32BE(2) * 4294967296 + buf.readUInt32BE(6); off = 10;
        }
        var key = null;
        if (masked) {
            if (buf.length < off + 4) return null;
            key = buf.slice(off, off + 4); off += 4;
        }
        if (buf.length < off + len) return null;
        var payload = Buffer.from(buf.slice(off, off + len));
        if (key) for (var i = 0; i < len; i++) payload[i] ^= key[i % 4];
        return { opcode: opcode, payload: payload, rest: buf.slice(off + len) };
    }

    function WsConnection(socket) {
        EventEmitter.call(this);
        var self = this;
        this.socket = socket;
        this.buffer = Buffer.alloc(0);
        this.readyState = 1;
        socket.on("data", function (d) { self._data(d); });
        socket.on("close", function () { self.readyState = 3; self.emit("close", 1006, ""); });
        socket.on("error", function (e) { self.emit("error", e); });
    }
    WsConnection.prototype = Object.create(EventEmitter.prototype);
    WsConnection.prototype.constructor = WsConnection;
    WsConnection.prototype._data = function (d) {
        this.buffer = Buffer.concat([this.buffer, d]);
        for (;;) {
            var f = wsDecode(this.buffer);
            if (!f) return;
            this.buffer = f.rest;
            if (f.opcode === 1) this.emit("message", f.payload.toString());
            else if (f.opcode === 2) this.emit("message", f.payload);
            else if (f.opcode === 8) {
                this.readyState = 2;
                try { this.socket.write(wsEncode(8, f.payload, false)); } catch (e) {}
                this.socket.end();
            } else if (f.opcode === 9) this.socket.write(wsEncode(10, f.payload, false));
            else if (f.opcode === 10) this.emit("pong", f.payload);
        }
    };
    WsConnection.prototype.send = function (data) {
        if (this.readyState !== 1) throw new Error("WebSocket is not open");
        this.socket.write(wsEncode(1, data, false));
    };
    WsConnection.prototype.close = function (code, reason) {
        if (this.readyState !== 1) return;
        this.readyState = 2;
        var payload = Buffer.alloc(2);
        payload.writeUInt16BE(code || 1000, 0);
        if (reason) payload = Buffer.concat([payload, Buffer.from(String(reason))]);
        this.socket.write(wsEncode(8, payload, false));
        this.socket.end();
    };

    function WebSocket(url) {
        EventEmitter.call(this);
        var m = /^ws:\/\/([^\/:]+)(?::(\d+))?(\/.*)?$/.exec(String(url));
        if (!m) throw new TypeError("only ws:// URLs are supported");
        var self = this;
        this.url = String(url);
        this.readyState = 0;
        this.buffer = Buffer.alloc(0);
        this._key = cryptoModule.randomBytes(16).toString("base64");
        this.socket = netModule.connect(Number(m[2] || 80), m[1]);
        this.socket.on("connect", function () {
            var path = m[3] || "/";
            self.socket.write("GET " + path + " HTTP/1.1\r\nHost: " + m[1] + ":" + Number(m[2] || 80) +
                "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + self._key +
                "\r\nSec-WebSocket-Version: 13\r\n\r\n");
        });
        this.socket.on("data", function (d) { self._data(d); });
        this.socket.on("close", function () {
            if (self.readyState !== 3) { self.readyState = 3; self.emit("close", 1006, ""); }
        });
        this.socket.on("error", function (e) { self.emit("error", e); });
    }
    WebSocket.prototype = Object.create(EventEmitter.prototype);
    WebSocket.prototype.constructor = WebSocket;
    WebSocket.prototype._data = function (d) {
        if (this.readyState === 0) {
            this.buffer = Buffer.concat([this.buffer, d]);
            var end = findBytes(this.buffer, [13, 10, 13, 10]);
            if (end < 0) return;
            var head = this.buffer.slice(0, end).toString();
            this.buffer = this.buffer.slice(end + 4);
            var lines = head.split("\r\n");
            if (!/^HTTP\/1\.1 101/.test(lines[0])) {
                this.emit("error", new Error("WebSocket handshake failed: " + lines[0]));
                this.socket.end();
                return;
            }
            var headers = {};
            for (var i = 1; i < lines.length; i++) {
                var idx = lines[i].indexOf(":");
                if (idx > 0) headers[lines[i].slice(0, idx).trim().toLowerCase()] = lines[i].slice(idx + 1).trim();
            }
            if (headers["sec-websocket-accept"] !== wsAccept(this._key)) {
                this.emit("error", new Error("WebSocket accept mismatch"));
                this.socket.end();
                return;
            }
            this.readyState = 1;
            this.emit("open");
            if (this.buffer.length === 0) return;
            d = this.buffer;
            this.buffer = Buffer.alloc(0);
        }
        this.buffer = Buffer.concat([this.buffer, d]);
        for (;;) {
            var f = wsDecode(this.buffer);
            if (!f) return;
            this.buffer = f.rest;
            if (f.opcode === 1) this.emit("message", f.payload.toString());
            else if (f.opcode === 2) this.emit("message", f.payload);
            else if (f.opcode === 8) {
                this.readyState = 3;
                this.socket.end();
                this.emit("close", 1000, f.payload.length >= 2 ? f.payload.readUInt16BE(0) : 1005);
            } else if (f.opcode === 9) this.socket.write(wsEncode(10, f.payload, true));
            else if (f.opcode === 10) this.emit("pong", f.payload);
        }
    };
    WebSocket.prototype.send = function (data) {
        if (this.readyState !== 1) throw new Error("WebSocket is not open");
        this.socket.write(wsEncode(1, data, true));
    };
    WebSocket.prototype.close = function (code, reason) {
        if (this.readyState !== 1) return;
        this.readyState = 2;
        var payload = Buffer.alloc(2);
        payload.writeUInt16BE(code || 1000, 0);
        if (reason) payload = Buffer.concat([payload, Buffer.from(String(reason))]);
        this.socket.write(wsEncode(8, payload, true));
    };
    WebSocket.prototype.terminate = function () { this.readyState = 3; this.socket.destroy(); };

    function WebSocketServer(options, listener) {
        EventEmitter.call(this);
        if (typeof options === "number") options = { port: options };
        options = options || {};
        var self = this;
        this._server = netModule.createServer(function (sock) { self._handshake(sock); });
        if (listener) this.on("connection", listener);
        if (options.port !== undefined) this.listen(options.port, options.host);
    }
    WebSocketServer.prototype = Object.create(EventEmitter.prototype);
    WebSocketServer.prototype.constructor = WebSocketServer;
    WebSocketServer.prototype.listen = function (port, host, cb) {
        if (typeof host === "function") { cb = host; host = undefined; }
        this._server.listen(port, host || "127.0.0.1", cb);
        return this;
    };
    WebSocketServer.prototype.address = function () { return this._server.address(); };
    WebSocketServer.prototype.close = function (cb) { this._server.close(cb); };
    WebSocketServer.prototype._handshake = function (sock) {
        var self = this;
        var buf = Buffer.alloc(0);
        function onData(d) {
            buf = Buffer.concat([buf, d]);
            var end = findBytes(buf, [13, 10, 13, 10]);
            if (end < 0) {
                if (buf.length > 16384) sock.destroy();
                return;
            }
            sock.removeListener("data", onData);
            var head = buf.slice(0, end).toString();
            var rest = buf.slice(end + 4);
            var lines = head.split("\r\n");
            var headers = {};
            for (var i = 1; i < lines.length; i++) {
                var idx = lines[i].indexOf(":");
                if (idx > 0) headers[lines[i].slice(0, idx).trim().toLowerCase()] = lines[i].slice(idx + 1).trim();
            }
            var key = headers["sec-websocket-key"];
            if (!key) { sock.end("HTTP/1.1 400 Bad Request\r\n\r\n"); return; }
            sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                wsAccept(key) + "\r\n\r\n");
            var conn = new WsConnection(sock);
            self.emit("connection", conn);
            if (rest.length) conn._data(rest);
        }
        sock.on("data", onData);
        sock.on("error", function () {});
    };

    var wsModule = { WebSocket: WebSocket, WebSocketServer: WebSocketServer };


    // ---- HTTP/2 (h2c) ------------------------------------------------------
    var H2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    var H2_STATIC = [[":authority",""],[":method","GET"],[":method","POST"],[":path","/"],[":path","/index.html"],[":scheme","http"],[":scheme","https"],[":status","200"],[":status","204"],[":status","206"],[":status","304"],[":status","400"],[":status","404"],[":status","500"],["accept-charset",""],["accept-encoding","gzip, deflate"],["accept-language",""],["accept-ranges",""],["accept",""],["access-control-allow-origin",""],["age",""],["allow",""],["authorization",""],["cache-control",""],["content-disposition",""],["content-encoding",""],["content-language",""],["content-length",""],["content-location",""],["content-range",""],["content-type",""],["cookie",""],["date",""],["etag",""],["expect",""],["expires",""],["from",""],["host",""],["if-match",""],["if-modified-since",""],["if-none-match",""],["if-range",""],["if-unmodified-since",""],["last-modified",""],["link",""],["location",""],["max-forwards",""],["proxy-authenticate",""],["proxy-authorization",""],["range",""],["referer",""],["refresh",""],["retry-after",""],["server",""],["set-cookie",""],["strict-transport-security",""],["transfer-encoding",""],["user-agent",""],["vary",""],["via",""],["www-authenticate",""]];
    var H2_HUFF = [8184,13,8388568,23,268435426,28,268435427,28,268435428,28,268435429,28,268435430,28,268435431,28,268435432,28,16777194,24,1073741820,30,268435433,28,268435434,28,1073741821,30,268435435,28,268435436,28,268435437,28,268435438,28,268435439,28,268435440,28,268435441,28,268435442,28,1073741822,30,268435443,28,268435444,28,268435445,28,268435446,28,268435447,28,268435448,28,268435449,28,268435450,28,268435451,28,20,6,1016,10,1017,10,4090,12,8185,13,21,6,248,8,2042,11,1018,10,1019,10,249,8,2043,11,250,8,22,6,23,6,24,6,0,5,1,5,2,5,25,6,26,6,27,6,28,6,29,6,30,6,31,6,92,7,251,8,32764,15,32,6,4091,12,1020,10,8186,13,33,6,93,7,94,7,95,7,96,7,97,7,98,7,99,7,100,7,101,7,102,7,103,7,104,7,105,7,106,7,107,7,108,7,109,7,110,7,111,7,112,7,113,7,114,7,252,8,115,7,253,8,8187,13,524272,19,8188,13,16380,14,34,6,32765,15,3,5,35,6,4,5,36,6,5,5,37,6,38,6,39,6,6,5,116,7,117,7,40,6,41,6,42,6,7,5,43,6,118,7,44,6,8,5,9,5,45,6,119,7,120,7,121,7,122,7,123,7,32766,15,2044,11,16381,14,8189,13,268435452,28,1048550,20,4194258,22,1048551,20,1048552,20,4194259,22,4194260,22,4194261,22,8388569,23,4194262,22,8388570,23,8388571,23,8388572,23,8388573,23,8388574,23,16777195,24,8388575,23,16777196,24,16777197,24,4194263,22,8388576,23,16777198,24,8388577,23,8388578,23,8388579,23,8388580,23,2097116,21,4194264,22,8388581,23,4194265,22,8388582,23,8388583,23,16777199,24,4194266,22,2097117,21,1048553,20,4194267,22,4194268,22,8388584,23,8388585,23,2097118,21,8388586,23,4194269,22,4194270,22,16777200,24,2097119,21,4194271,22,8388587,23,8388588,23,2097120,21,2097121,21,4194272,22,2097122,21,8388589,23,4194273,22,8388590,23,8388591,23,1048554,20,4194274,22,4194275,22,4194276,22,8388592,23,4194277,22,4194278,22,8388593,23,67108832,26,67108833,26,1048555,20,524273,19,4194279,22,8388594,23,4194280,22,33554412,25,67108834,26,67108835,26,67108836,26,134217694,27,134217695,27,67108837,26,16777201,24,33554413,25,524274,19,2097123,21,67108838,26,134217696,27,134217697,27,67108839,26,134217698,27,16777202,24,2097124,21,2097125,21,67108840,26,67108841,26,268435453,28,134217699,27,134217700,27,134217701,27,1048556,20,16777203,24,1048557,20,2097126,21,4194281,22,2097127,21,2097128,21,8388595,23,4194282,22,4194283,22,33554414,25,33554415,25,16777204,24,16777205,24,67108842,26,8388596,23,67108843,26,134217702,27,67108844,26,67108845,26,134217703,27,134217704,27,134217705,27,134217706,27,134217707,27,268435454,28,134217708,27,134217709,27,134217710,27,134217711,27,134217712,27,67108846,26,1073741823,30];
    var h2HuffMaps = null;

    function h2BuildHuffMaps() {
        if (h2HuffMaps) return h2HuffMaps;
        var maps = [];
        for (var i = 0; i < H2_HUFF.length; i += 2) {
            var code = H2_HUFF[i], len = H2_HUFF[i + 1];
            if (!maps[len]) maps[len] = {};
            maps[len][code] = i / 2;
        }
        h2HuffMaps = maps;
        return maps;
    }

    function h2HuffDecode(bytes) {
        var maps = h2BuildHuffMaps();
        var out = [], code = 0, len = 0;
        for (var i = 0; i < bytes.length; i++) {
            for (var bit = 7; bit >= 0; bit--) {
                code = code * 2 + ((bytes[i] >> bit) & 1);
                len++;
                var m = maps[len];
                if (m && m[code] !== undefined) {
                    var sym = m[code];
                    if (sym === 256) return Buffer.from(out);
                    out.push(sym);
                    code = 0; len = 0;
                }
            }
        }
        return Buffer.from(out);
    }

    function h2Int(buf, off, prefix) {
        var mask = (1 << prefix) - 1;
        var value = buf[off] & mask;
        var i = off + 1;
        if (value < mask) return [value, i];
        var shift = 0;
        for (;;) {
            var b = buf[i++];
            value += (b & 127) * Math.pow(2, shift);
            shift += 7;
            if (!(b & 128)) break;
        }
        return [value, i];
    }

    function h2String(buf, off) {
        var huff = (buf[off] & 0x80) !== 0;
        var r = h2Int(buf, off, 7);
        var raw = buf.slice(r[1], r[1] + r[0]);
        return [huff ? h2HuffDecode(raw).toString() : raw.toString(), r[1] + r[0]];
    }

    function h2EncInt(value, prefix, first) {
        var max = (1 << prefix) - 1;
        if (value < max) return Buffer.from([first | value]);
        var out = [first | max];
        value -= max;
        while (value >= 128) { out.push((value % 128) + 128); value = Math.floor(value / 128); }
        out.push(value);
        return Buffer.from(out);
    }

    function h2EncString(s) {
        var b = Buffer.from(String(s));
        return Buffer.concat([h2EncInt(b.length, 7, 0), b]);
    }

    function H2Table() {
        this.entries = [];
        this.size = 0;
        this.max = 4096;
    }
    H2Table.prototype.get = function (idx) {
        if (idx === 0) return null;
        if (idx <= H2_STATIC.length) return H2_STATIC[idx - 1];
        return this.entries[idx - H2_STATIC.length - 1] || null;
    };
    H2Table.prototype.add = function (name, value) {
        var sz = Buffer.byteLength(name) + Buffer.byteLength(value) + 32;
        this.entries.unshift([name, value]);
        this.size += sz;
        this._evict();
    };
    H2Table.prototype._evict = function () {
        while (this.size > this.max && this.entries.length) {
            var e = this.entries.pop();
            this.size -= Buffer.byteLength(e[0]) + Buffer.byteLength(e[1]) + 32;
        }
    };
    H2Table.prototype.setMax = function (m) { this.max = m; this._evict(); };

    function h2StaticIndex(name, value) {
        for (var i = 0; i < H2_STATIC.length; i++) {
            if (H2_STATIC[i][0] === name && H2_STATIC[i][1] === value) return i + 1;
        }
        return 0;
    }
    function h2StaticName(name) {
        for (var i = 0; i < H2_STATIC.length; i++) {
            if (H2_STATIC[i][0] === name) return i + 1;
        }
        return 0;
    }

    function h2EncodeHeaders(headers) {
        var parts = [];
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            var name = String(k).toLowerCase(), value = String(headers[k]);
            var exact = h2StaticIndex(name, value);
            if (exact) { parts.push(h2EncInt(exact, 7, 0x80)); continue; }
            var ni = h2StaticName(name);
            var head;
            if (ni > 0 && ni < 16) head = Buffer.from([ni]);
            else head = Buffer.concat([Buffer.from([0]), h2EncString(name)]);
            parts.push(Buffer.concat([head, h2EncString(value)]));
        }
        return Buffer.concat(parts);
    }

    function h2DecodeHeaders(buf, table) {
        var out = [], off = 0;
        while (off < buf.length) {
            var b = buf[off];
            if (b & 0x80) {
                var r = h2Int(buf, off, 7);
                var e = table.get(r[0]);
                if (!e) throw new Error("bad HPACK index " + r[0]);
                out.push([e[0], e[1]]);
                off = r[1];
            } else if (b & 0x40) {
                var r2 = h2Int(buf, off, 6), name, val;
                if (r2[0] === 0) { var s = h2String(buf, r2[1]); name = s[0]; off = s[1]; }
                else { name = table.get(r2[0])[0]; off = r2[1]; }
                var sv = h2String(buf, off); val = sv[0]; off = sv[1];
                table.add(name, val);
                out.push([name, val]);
            } else if (b & 0x20) {
                var r3 = h2Int(buf, off, 5);
                table.setMax(r3[0]);
                off = r3[1];
            } else {
                var r4 = h2Int(buf, off, 4), name2, val2;
                if (r4[0] === 0) { var s2 = h2String(buf, r4[1]); name2 = s2[0]; off = s2[1]; }
                else { name2 = table.get(r4[0])[0]; off = r4[1]; }
                var sv2 = h2String(buf, off); val2 = sv2[0]; off = sv2[1];
                out.push([name2, val2]);
            }
        }
        return out;
    }

    function h2Frame(type, flags, streamId, payload) {
        payload = payload || Buffer.alloc(0);
        var h = Buffer.alloc(9);
        h[0] = (payload.length >> 16) & 255;
        h[1] = (payload.length >> 8) & 255;
        h[2] = payload.length & 255;
        h[3] = type;
        h[4] = flags;
        wsW32(h, 5, streamId & 0x7fffffff);
        return Buffer.concat([h, payload]);
    }

    function h2HeadersToObject(list) {
        var o = {};
        for (var i = 0; i < list.length; i++) o[list[i][0]] = list[i][1];
        return o;
    }

    function H2Stream(session, id, headers) {
        EventEmitter.call(this);
        this.session = session;
        this.id = id;
        this.headers = headers || {};
        this.closed = false;
    }
    H2Stream.prototype = Object.create(EventEmitter.prototype);
    H2Stream.prototype.constructor = H2Stream;
    H2Stream.prototype.write = function (chunk) {
        var b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
        this.session._send(h2Frame(0, 0, this.id, b));
        return true;
    };
    H2Stream.prototype.end = function (chunk) {
        var b = chunk === undefined ? Buffer.alloc(0) : (Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
        this.session._send(h2Frame(0, 0x1, this.id, b));
        this.closed = true;
        return this;
    };
    H2Stream.prototype.respond = function (headers) {
        this.session._send(h2Frame(1, 0x4, this.id, h2EncodeHeaders(headers)));
        return this;
    };

    function H2Session(socket, isServer) {
        EventEmitter.call(this);
        var self = this;
        this.socket = socket;
        this.isServer = isServer;
        this.buf = Buffer.alloc(0);
        this.table = new H2Table();
        this.nextId = isServer ? 2 : 1;
        this.streams = {};
        this._out = [];
        this._ready = isServer;
        this._prefaceDone = !isServer;
        this.closed = false;
        socket.on("data", function (d) { self._data(d); });
        socket.on("close", function () {
            if (!self.closed) { self.closed = true; self.emit("close"); }
        });
        socket.on("error", function (e) { self.emit("error", e); });
        if (!isServer) {
            socket.on("connect", function () {
                self._ready = true;
                socket.write(Buffer.from(H2_PREFACE));
                socket.write(h2Frame(4, 0, 0, Buffer.alloc(0)));
                for (var qi = 0; qi < self._out.length; qi++) socket.write(self._out[qi]);
                self._out = [];
            });
        }
    }
    H2Session.prototype = Object.create(EventEmitter.prototype);
    H2Session.prototype.constructor = H2Session;
    H2Session.prototype._send = function (buf) {
        if (this._ready) this.socket.write(buf);
        else this._out.push(buf);
    };
    H2Session.prototype._data = function (d) {
        this.buf = Buffer.concat([this.buf, d]);
        if (this.isServer && !this._prefaceDone && this.buf.length >= H2_PREFACE.length) {
            if (this.buf.slice(0, H2_PREFACE.length).toString() === H2_PREFACE) {
                this.buf = this.buf.slice(H2_PREFACE.length);
                this._prefaceDone = true;
                this.socket.write(h2Frame(4, 0, 0, Buffer.alloc(0)));
            } else {
                this.socket.destroy();
                return;
            }
        }
        for (;;) {
            if (this.buf.length < 9) return;
            var len = this.buf[0] * 65536 + this.buf[1] * 256 + this.buf[2];
            if (this.buf.length < 9 + len) return;
            var type = this.buf[3], flags = this.buf[4];
            var id = this.buf.readUInt32BE(5) & 0x7fffffff;
            var payload = this.buf.slice(9, 9 + len);
            this.buf = this.buf.slice(9 + len);
            // A hostile peer only needs one malformed frame (a bad HPACK
            // index throws). Malformed frames kill the session, never the
            // process: the throw must not escape into the native read
            // callback, where it becomes an uncaught exception.
            try {
                this._frame(type, flags, id, payload);
            } catch (e) {
                // Emit only when a listener exists: an unhandled 'error'
                // rethrows on this EventEmitter and would take the process
                // down from inside the catch.
                if (this._events && this._events.error && this._events.error.length)
                    this.emit("error", e);
                this.socket.destroy();
                return;
            }
        }
    };
    H2Session.prototype._frame = function (type, flags, id, payload) {
        if (type === 4) { // SETTINGS
            if (!(flags & 0x1)) this._send(h2Frame(4, 0x1, 0, Buffer.alloc(0)));
            return;
        }
        if (type === 6) { // PING
            if (!(flags & 0x1)) this._send(h2Frame(6, 0x1, 0, payload));
            return;
        }
        if (type === 1) { // HEADERS
            var off = 0;
            if (flags & 0x8) off = 1 + payload[0];
            if (flags & 0x20) off += 5;
            var block = payload.slice(off);
            var list = h2DecodeHeaders(block, this.table);
            var headers = h2HeadersToObject(list);
            var stream = this.isServer ? new H2Stream(this, id, headers) : (this.streams[id] || null);
            if (this.isServer) {
                if (!this.streams) this.streams = {};
                this.streams[id] = stream;
                this.emit("stream", stream, headers);
            } else if (stream) {
                this.streams[id] = stream;
                stream.emit("response", headers);
            }
            return;
        }
        if (type === 0) { // DATA
            var s = this.streams && this.streams[id];
            if (!s) return;
            var off2 = 0, data = payload;
            if (flags & 0x8) { off2 = 1 + payload[0]; data = payload.slice(off2); }
            if (data.length) s.emit("data", data);
            if (flags & 0x1) { s.closed = true; s.emit("end"); delete this.streams[id]; }
            return;
        }
        if (type === 3) { // RST_STREAM
            var rs = this.streams && this.streams[id];
            if (rs) { rs.emit("error", new Error("stream reset")); delete this.streams[id]; }
            return;
        }
        if (type === 7) { // GOAWAY
            this.closed = true;
            this.emit("close");
            return;
        }
    };
    H2Session.prototype.request = function (headers, options) {
        var id = this.nextId;
        this.nextId += 2;
        var stream = new H2Stream(this, id, headers);
        if (!this.streams) this.streams = {};
        this.streams[id] = stream;
        var endStream = options && options.endStream === false ? 0 : 0x1;
        this._send(h2Frame(1, 0x4 | endStream, id, h2EncodeHeaders(headers)));
        return stream;
    };
    H2Session.prototype.close = function () { this.closed = true; this.socket.end(); };

    function h2Connect(url, options) {
        var m = /^(https?):\/\/([^\/:]+)(?::(\d+))?(\/.*)?$/.exec(String(url));
        if (!m) throw new TypeError("http2.connect requires an http(s) URL");
        options = options || {};
        var port = Number(m[3] || (m[1] === "https" ? 443 : 80));
        var socket;
        if (m[1] === "https") {
            socket = tlsModule.connect({
                host: m[2], port: port, servername: options.servername || m[2],
                alpn: "h2", caFile: options.caFile, ca: options.ca,
                certFile: options.certFile, keyFile: options.keyFile,
                rejectUnauthorized: options.rejectUnauthorized !== false
            });
        } else {
            socket = netModule.connect(port, m[2]);
        }
        return new H2Session(socket, false);
    }

    function h2CreateServer(options, listener) {
        if (typeof options === "function") { listener = options; options = {}; }
        var server = netModule.createServer(function (socket) {
                        var session = new H2Session(socket, true);
            server.emit("session", session);
        });
        if (listener) server.on("stream", listener);
        server.on("session", function (session) {
            session.on("stream", function (stream, headers) { server.emit("stream", stream, headers); });
        });
        return server;
    }

    function h2CreateSecureServer(options, listener) {
        if (typeof options === "function") { listener = options; options = {}; }
        var opts = {};
        for (var k in (options || {})) opts[k] = options[k];
        if (!opts.alpn) opts.alpn = "h2";
        var server = tlsModule.createServer(opts);
        server.on("secureConnection", function (socket) {
            if (socket.alpnProtocol !== "h2") { socket.destroy(); return; }
            var session = new H2Session(socket, true);
            server.emit("session", session);
        });
        if (listener) server.on("stream", listener);
        server.on("session", function (session) {
            session.on("stream", function (stream, headers) { server.emit("stream", stream, headers); });
        });
        return server;
    }

    var http2Constants = (function () {
        var out = {};
        var headers = [
            [':authority', 'AUTHORITY'], [':method', 'METHOD'], [':path', 'PATH'],
            [':scheme', 'SCHEME'], [':status', 'STATUS'], [':protocol', 'PROTOCOL'],
            ['accept', 'ACCEPT'], ['accept-charset', 'ACCEPT_CHARSET'],
            ['accept-encoding', 'ACCEPT_ENCODING'], ['accept-language', 'ACCEPT_LANGUAGE'],
            ['accept-ranges', 'ACCEPT_RANGES'], ['access-control-allow-credentials', 'ACCESS_CONTROL_ALLOW_CREDENTIALS'],
            ['access-control-allow-headers', 'ACCESS_CONTROL_ALLOW_HEADERS'],
            ['access-control-allow-methods', 'ACCESS_CONTROL_ALLOW_METHODS'],
            ['access-control-allow-origin', 'ACCESS_CONTROL_ALLOW_ORIGIN'],
            ['access-control-expose-headers', 'ACCESS_CONTROL_EXPOSE_HEADERS'],
            ['access-control-max-age', 'ACCESS_CONTROL_MAX_AGE'],
            ['access-control-request-headers', 'ACCESS_CONTROL_REQUEST_HEADERS'],
            ['access-control-request-method', 'ACCESS_CONTROL_REQUEST_METHOD'],
            ['age', 'AGE'], ['allow', 'ALLOW'], ['authorization', 'AUTHORIZATION'],
            ['cache-control', 'CACHE_CONTROL'], ['connection', 'CONNECTION'],
            ['content-disposition', 'CONTENT_DISPOSITION'], ['content-encoding', 'CONTENT_ENCODING'],
            ['content-language', 'CONTENT_LANGUAGE'], ['content-length', 'CONTENT_LENGTH'],
            ['content-location', 'CONTENT_LOCATION'], ['content-range', 'CONTENT_RANGE'],
            ['content-type', 'CONTENT_TYPE'], ['cookie', 'COOKIE'], ['date', 'DATE'],
            ['dnt', 'DNT'], ['etag', 'ETAG'], ['expect', 'EXPECT'], ['expires', 'EXPIRES'],
            ['from', 'FROM'], ['host', 'HOST'], ['if-match', 'IF_MATCH'],
            ['if-modified-since', 'IF_MODIFIED_SINCE'], ['if-none-match', 'IF_NONE_MATCH'],
            ['if-range', 'IF_RANGE'], ['if-unmodified-since', 'IF_UNMODIFIED_SINCE'],
            ['last-modified', 'LAST_MODIFIED'], ['link', 'LINK'], ['location', 'LOCATION'],
            ['max-forwards', 'MAX_FORWARDS'], ['origin', 'ORIGIN'], ['pragma', 'PRAGMA'],
            ['proxy-authenticate', 'PROXY_AUTHENTICATE'], ['proxy-authorization', 'PROXY_AUTHORIZATION'],
            ['range', 'RANGE'], ['referer', 'REFERER'], ['refresh', 'REFRESH'],
            ['retry-after', 'RETRY_AFTER'], ['server', 'SERVER'], ['set-cookie', 'SET_COOKIE'],
            ['strict-transport-security', 'STRICT_TRANSPORT_SECURITY'], ['te', 'TE'], ['trailer', 'TRAILER'],
            ['transfer-encoding', 'TRANSFER_ENCODING'], ['upgrade', 'UPGRADE'],
            ['user-agent', 'USER_AGENT'], ['vary', 'VARY'], ['via', 'VIA'],
            ['www-authenticate', 'WWW_AUTHENTICATE']
        ];
        for (var i = 0; i < headers.length; i++) out['HTTP2_HEADER_' + headers[i][1]] = headers[i][0];
        var methods = ['GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS', 'TRACE', 'CONNECT', 'PATCH'];
        for (var j = 0; j < methods.length; j++) out['HTTP2_METHOD_' + methods[j]] = methods[j];
        var errors = {
            NO_ERROR: 0, PROTOCOL_ERROR: 1, INTERNAL_ERROR: 2, FLOW_CONTROL_ERROR: 3,
            SETTINGS_TIMEOUT: 4, STREAM_CLOSED: 5, FRAME_SIZE_ERROR: 6, REFUSED_STREAM: 7,
            CANCEL: 8, COMPRESSION_ERROR: 9, CONNECT_ERROR: 10, ENHANCE_YOUR_CALM: 11,
            INADEQUATE_SECURITY: 12, HTTP_1_1_REQUIRED: 13
        };
        for (var k in errors) out['HTTP2_ERROR_' + k] = errors[k];
        var settings = {
            HEADER_TABLE_SIZE: 1, ENABLE_PUSH: 2, MAX_CONCURRENT_STREAMS: 3,
            INITIAL_WINDOW_SIZE: 4, MAX_FRAME_SIZE: 5, MAX_HEADER_LIST_SIZE: 6
        };
        for (var s in settings) out['HTTP2_SETTINGS_' + s] = settings[s];
        out.HTTP2_DEBUG = Symbol.for('nodejs.http2.debug');
        out.HTTP2_DEBUG_SESSION = Symbol.for('nodejs.http2.debugSession');
        out.HTTP2_DEBUG_ENGINE = Symbol.for('nodejs.http2.debugEngine');
        return out;
    })();

    var http2Module = {
        constants: http2Constants,
        connect: h2Connect,
        createServer: h2CreateServer,
        createSecureServer: h2CreateSecureServer,
        Http2Session: H2Session
    };


    // ---- WebCrypto (subset) -------------------------------------------
    function subtleBytes(data) {
        if (Buffer.isBuffer(data)) return data;
        if (data instanceof ArrayBuffer) return Buffer.from(data);
        if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
        throw new TypeError('Expected a BufferSource');
    }
    function subtleAlgName(a) { return typeof a === 'string' ? a : (a && a.name); }
    function subtleHash(hash) {
        var h = typeof hash === 'string' ? hash : (hash && hash.name) || 'SHA-256';
        return h.toLowerCase().replace(/-/g, '');
    }
    function subtleB64u(buf) {
        return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }
    function subtleFromB64u(str) {
        var s = String(str).replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        return Buffer.from(s, 'base64');
    }
    function subtlePem(der, label) {
        var b64 = Buffer.from(der).toString('base64').match(/.{1,64}/g).join('\n');
        return '-----BEGIN ' + label + '-----\n' + b64 + '\n-----END ' + label + '-----\n';
    }
    function subtleDerLen(n) {
        if (n < 128) return Buffer.from([n]);
        var bytes = [];
        while (n > 0) { bytes.unshift(n & 0xFF); n >>= 8; }
        return Buffer.from([0x80 | bytes.length].concat(bytes));
    }
    function subtleDer(tag, content) {
        var body = Buffer.isBuffer(content) ? content : Buffer.from(content);
        return Buffer.concat([Buffer.from([tag]), subtleDerLen(body.length), body]);
    }
    function subtleDerInt(bytes) {
        var b = Buffer.from(bytes);
        var i = 0;
        while (i < b.length - 1 && b[i] === 0) i++;
        b = b.slice(i);
        if (b.length && (b[0] & 0x80)) b = Buffer.concat([Buffer.from([0]), b]);
        return subtleDer(0x02, b);
    }
    function subtleDerSeq(parts) { return subtleDer(0x30, Buffer.concat(parts)); }
    function subtleDerOid(bytes) { return subtleDer(0x06, Buffer.from(bytes)); }
    function subtleDerNull() { return Buffer.from([0x05, 0x00]); }
    function subtleDerBitString(content) { return subtleDer(0x03, Buffer.concat([Buffer.from([0]), content])); }

    var SUBTLE_RSA_ALG = subtleDerSeq([subtleDerOid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), subtleDerNull()]);
    var SUBTLE_EC_OID = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];
    var SUBTLE_CURVES = {
        'P-256': { oid: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07], size: 32, gen: 'prime256v1' },
        'P-384': { oid: [0x2B, 0x81, 0x04, 0x00, 0x22], size: 48, gen: 'secp384r1' },
        'P-521': { oid: [0x2B, 0x81, 0x04, 0x00, 0x23], size: 66, gen: 'secp521r1' }
    };
    function subtleRsaPublicPem(jwk) {
        var n = subtleFromB64u(jwk.n), e = subtleFromB64u(jwk.e);
        var rsa = subtleDerSeq([subtleDerInt(n), subtleDerInt(e)]);
        return subtlePem(subtleDerSeq([SUBTLE_RSA_ALG, subtleDerBitString(rsa)]), 'PUBLIC KEY');
    }
    function subtleRsaPrivatePem(jwk) {
        var parts = ['n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi'].map(function (k) { return subtleDerInt(subtleFromB64u(jwk[k])); });
        var rsa = subtleDerSeq([subtleDerInt([0])].concat(parts));
        return subtlePem(subtleDerSeq([subtleDerInt([0]), SUBTLE_RSA_ALG, subtleDer(0x04, rsa)]), 'PRIVATE KEY');
    }
    function subtleEcPublicPem(jwk) {
        var curve = SUBTLE_CURVES[jwk.crv];
        if (!curve) throw subtleError('NotSupportedError', 'unsupported curve');
        var alg = subtleDerSeq([subtleDerOid(SUBTLE_EC_OID), subtleDerOid(curve.oid)]);
        var point = Buffer.concat([Buffer.from([0x04]), Buffer.from(subtleFromB64u(jwk.x)), Buffer.from(subtleFromB64u(jwk.y))]);
        return subtlePem(subtleDerSeq([alg, subtleDerBitString(point)]), 'PUBLIC KEY');
    }
    function subtleEcPrivatePem(jwk) {
        var curve = SUBTLE_CURVES[jwk.crv];
        if (!curve) throw subtleError('NotSupportedError', 'unsupported curve');
        var alg = subtleDerSeq([subtleDerOid(SUBTLE_EC_OID), subtleDerOid(curve.oid)]);
        var point = Buffer.concat([Buffer.from([0x04]), Buffer.from(subtleFromB64u(jwk.x)), Buffer.from(subtleFromB64u(jwk.y))]);
        var key = subtleDerSeq([
            subtleDerInt([1]),
            subtleDer(0x04, Buffer.from(subtleFromB64u(jwk.d))),
            subtleDer(0xA0, subtleDerOid(curve.oid)),
            subtleDer(0xA1, subtleDerBitString(point))
        ]);
        return subtlePem(subtleDerSeq([subtleDerInt([0]), alg, subtleDer(0x04, key)]), 'PRIVATE KEY');
    }

    function subtleError(name, message) {
        var e = new Error(message);
        e.name = name;
        return e;
    }
    function CryptoKey(type, algorithm, extractable, usages, secret, pem) {
        this.type = type;
        this.algorithm = algorithm;
        this.extractable = !!extractable;
        this.usages = usages || [];
        this._secret = secret || null;
        this._pem = pem || null;
    }
    function subtleNormalize(algorithm) {
        if (typeof algorithm === 'string') return { name: algorithm };
        var out = {};
        for (var k in algorithm) if (Object.prototype.hasOwnProperty.call(algorithm, k)) out[k] = algorithm[k];
        if (out.hash) out.hash = { name: typeof out.hash === 'string' ? out.hash : out.hash.name };
        return out;
    }
    function subtleDerToRaw(sig, size) {
        var i = 2, rLen = sig[i + 1], r = sig.slice(i + 2, i + 2 + rLen);
        i = i + 2 + rLen;
        var sLen = sig[i + 1], s = sig.slice(i + 2, i + 2 + sLen);
        function pad(b) { b = b[0] === 0 ? b.slice(1) : b; if (b.length > size) b = b.slice(b.length - size); return Buffer.concat([Buffer.alloc(size - b.length), b]); }
        return Buffer.concat([pad(r), pad(s)]);
    }
    function subtleRawToDer(raw, size) {
        var r = raw.slice(0, size), s = raw.slice(size);
        return subtleDerSeq([subtleDerInt(r), subtleDerInt(s)]);
    }

    var subtle = {
        digest: function (algorithm, data) {
            var hash = subtleHash(algorithm);
            return Promise.resolve().then(function () {
                var h = cryptoModule.createHash(hash);
                h.update(subtleBytes(data));
                var out = h.digest();
                return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
            });
        },
        importKey: function (format, keyData, algorithm, extractable, usages) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                if (format === 'raw') {
                    return new CryptoKey('secret', alg, extractable, usages, subtleBytes(keyData), null);
                }
                if (format === 'spki' || format === 'pkcs8') {
                    var kind = format === 'spki' ? 'public' : 'private';
                    var label = format === 'spki' ? 'PUBLIC KEY' : 'PRIVATE KEY';
                    return new CryptoKey(kind, alg, extractable, usages, null, subtlePem(subtleBytes(keyData), label));
                }
                if (format === 'jwk') {
                    if (keyData.kty === 'oct') return new CryptoKey('secret', alg, extractable, usages, subtleFromB64u(keyData.k), null);
                    if (keyData.kty === 'RSA' && keyData.d) return new CryptoKey('private', alg, extractable, usages, null, subtleRsaPrivatePem(keyData));
                    if (keyData.kty === 'RSA') return new CryptoKey('public', alg, extractable, usages, null, subtleRsaPublicPem(keyData));
                    if (keyData.kty === 'EC' && keyData.d) return new CryptoKey('private', alg, extractable, usages, null, subtleEcPrivatePem(keyData));
                    if (keyData.kty === 'EC') return new CryptoKey('public', alg, extractable, usages, null, subtleEcPublicPem(keyData));
                }
                throw subtleError('NotSupportedError', 'unsupported key format');
            });
        },
        exportKey: function (format, key) {
            return Promise.resolve().then(function () {
                if (format === 'raw') {
                    if (key.type !== 'secret' || !key.extractable) throw subtleError('InvalidAccessError', 'key is not extractable');
                    return key._secret.buffer.slice(key._secret.byteOffset, key._secret.byteOffset + key._secret.byteLength);
                }
                if (format === 'jwk') {
                    if (key.type !== 'secret') throw subtleError('NotSupportedError', 'asymmetric JWK export is not supported');
                    return { kty: 'oct', k: subtleB64u(key._secret), ext: true };
                }
                if (format === 'spki' || format === 'pkcs8') {
                    if (!key._pem) throw subtleError('InvalidAccessError', 'key has no PEM');
                    var body = key._pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
                    var buf = Buffer.from(body, 'base64');
                    return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
                }
                throw subtleError('NotSupportedError', 'unsupported export format');
            });
        },
        generateKey: function (algorithm, extractable, usages) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                var name = alg.name;
                if (name === 'HMAC') {
                    var bits = alg.length || 256;
                    return new CryptoKey('secret', alg, extractable, usages, cryptoModule.randomBytes(bits / 8), null);
                }
                if (name === 'AES-GCM' || name === 'AES-CBC') {
                    var len = alg.length || 256;
                    return new CryptoKey('secret', alg, extractable, usages, cryptoModule.randomBytes(len / 8), null);
                }
                if (name === 'RSASSA-PKCS1-v1_5' || name === 'RSA-OAEP') {
                    var pair = cryptoModule.generateKeyPairSync('rsa', { modulusLength: alg.modulusLength || 2048 });
                    return {
                        publicKey: new CryptoKey('public', alg, true, usages.filter(function (u) { return u === 'verify' || u === 'encrypt' || u === 'wrapKey'; }), null, pair.publicKey.export({ format: 'pem' })),
                        privateKey: new CryptoKey('private', alg, true, usages.filter(function (u) { return u === 'sign' || u === 'decrypt' || u === 'unwrapKey'; }), null, pair.privateKey.export({ format: 'pem' }))
                    };
                }
                if (name === 'ECDSA' || name === 'ECDH') {
                    var curve = alg.namedCurve || 'P-256';
                    var ec = cryptoModule.generateKeyPairSync('ec', { namedCurve: (SUBTLE_CURVES[curve] || SUBTLE_CURVES['P-256']).gen });
                    return {
                        publicKey: new CryptoKey('public', alg, true, usages, null, ec.publicKey.export({ format: 'pem' })),
                        privateKey: new CryptoKey('private', alg, true, usages, null, ec.privateKey.export({ format: 'pem' }))
                    };
                }
                throw subtleError('NotSupportedError', 'unsupported algorithm: ' + name);
            });
        },
        sign: function (algorithm, key, data) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                var hash = subtleHash(alg.hash || (key.algorithm && key.algorithm.hash) || 'SHA-256');
                var bytes = subtleBytes(data);
                if (key.algorithm.name === 'HMAC') {
                    var h = cryptoModule.createHmac(hash, key._secret);
                    h.update(bytes);
                    var mac = h.digest();
                    return mac.buffer.slice(mac.byteOffset, mac.byteOffset + mac.byteLength);
                }
                var sig = cryptoModule.sign(hash, bytes, key._pem);
                if (key.algorithm.name === 'ECDSA') {
                    var size = (SUBTLE_CURVES[key.algorithm.namedCurve || 'P-256'] || SUBTLE_CURVES['P-256']).size;
                    sig = subtleDerToRaw(sig, size);
                }
                return sig.buffer.slice(sig.byteOffset, sig.byteOffset + sig.byteLength);
            });
        },
        verify: function (algorithm, key, signature, data) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                var hash = subtleHash(alg.hash || (key.algorithm && key.algorithm.hash) || 'SHA-256');
                var bytes = subtleBytes(data);
                var sig = subtleBytes(signature);
                if (key.algorithm.name === 'HMAC') {
                    var h = cryptoModule.createHmac(hash, key._secret);
                    h.update(bytes);
                    var mac = h.digest();
                    return mac.length === sig.length && cryptoModule.timingSafeEqual(mac, sig);
                }
                if (key.algorithm.name === 'ECDSA') {
                    var size = (SUBTLE_CURVES[key.algorithm.namedCurve || 'P-256'] || SUBTLE_CURVES['P-256']).size;
                    sig = subtleRawToDer(sig, size);
                }
                return cryptoModule.verify(hash, bytes, key._pem, sig);
            });
        },
        encrypt: function (algorithm, key, data) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                if (alg.name !== 'AES-GCM') throw subtleError('NotSupportedError', 'only AES-GCM is supported');
                var bits = (key._secret.length * 8);
                var cipher = cryptoModule.createCipheriv('aes-' + bits + '-gcm', key._secret, subtleBytes(alg.iv));
                if (alg.additionalData) cipher.setAAD(subtleBytes(alg.additionalData));
                var body = Buffer.concat([cipher.update(subtleBytes(data)), cipher.final()]);
                var tag = cipher.getAuthTag();
                var out = Buffer.concat([body, tag]);
                return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
            });
        },
        decrypt: function (algorithm, key, data) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                if (alg.name !== 'AES-GCM') throw subtleError('NotSupportedError', 'only AES-GCM is supported');
                var all = subtleBytes(data);
                var tagLen = (alg.tagLength || 128) / 8;
                var body = all.slice(0, all.length - tagLen);
                var tag = all.slice(all.length - tagLen);
                var bits = (key._secret.length * 8);
                var decipher = cryptoModule.createDecipheriv('aes-' + bits + '-gcm', key._secret, subtleBytes(alg.iv));
                decipher.setAuthTag(tag);
                if (alg.additionalData) decipher.setAAD(subtleBytes(alg.additionalData));
                var out = Buffer.concat([decipher.update(body), decipher.final()]);
                return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
            });
        },
        deriveBits: function (algorithm, baseKey, length) {
            return Promise.resolve().then(function () {
                var alg = subtleNormalize(algorithm);
                if (alg.name === 'PBKDF2') {
                    var out = cryptoModule.pbkdf2Sync(baseKey._secret, subtleBytes(alg.salt), Number(alg.iterations), length / 8, subtleHash(alg.hash || 'SHA-256'));
                    return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
                }
                if (alg.name === 'HKDF') {
                    var okm = cryptoModule.hkdfSync(subtleHash(alg.hash || 'SHA-256'), baseKey._secret, subtleBytes(alg.salt || Buffer.alloc(0)), subtleBytes(alg.info || Buffer.alloc(0)), length / 8);
                    return okm.buffer.slice(okm.byteOffset, okm.byteOffset + okm.byteLength);
                }
                throw subtleError('NotSupportedError', 'unsupported derive algorithm');
            });
        },
        deriveKey: function (algorithm, baseKey, derivedKeyType, extractable, keyUsages) {
            var self = this;
            var bits = (subtleNormalize(derivedKeyType).length || 256);
            return self.deriveBits(algorithm, baseKey, bits).then(function (raw) {
                return self.importKey('raw', raw, derivedKeyType, extractable, keyUsages);
            });
        },
        CryptoKey: CryptoKey
    };
    cryptoModule.subtle = subtle;
    cryptoModule.webcrypto = cryptoModule;

    g.crypto = cryptoModule;
    g.zlib = zlibModule;
    g.child_process = childProcessModule;
    g.dns = dnsModule;
    g.dns_promises = dnsModule.promises;
    g.http = httpModule;
    g.ws = wsModule;
    g.http2 = http2Module;
    g.WebSocket = WebSocket;
    g.https = httpsModule;
    g.tls = tlsModule;
    g.fetch = fetch;
    g.Headers = FetchHeaders;
    g.Response = Response;
    g.Request = Request;
    g.FormData = FormData;
    g.Blob = Blob;
    g.File = File;

    g.console = consoleObj;
    g.setTimeout = setTimeout;
    g.setInterval = setInterval;
    g.clearTimeout = clearTimeout;
    g.clearInterval = clearTimeout;
    g.setImmediate = setImmediate;
    g.clearImmediate = clearImmediate;
    g.queueMicrotask = queueMicrotask;
    // process stdio streams and signal handlers (Node-shaped surface).
    function fdWritable(fd) {
        var w = new Writable({
            write: function (chunk, enc, cb) {
                var s = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
                __djs.console.write(fd, s);
                cb();
            }
        });
        w.fd = fd;
        w.isTTY = __djs.stdio.isattyFd(fd) === 1;
        w.columns = w.isTTY ? (Number(processObj.env.COLUMNS) || 80) : undefined;
        w.rows = w.isTTY ? (Number(processObj.env.LINES) || 24) : undefined;
        // tty.WriteStream.hasColors(), as implemented by supports-color.
        w.hasColors = function (count, env) {
            env = env || processObj.env || {};
            var force = env.FORCE_COLOR;
            if (force !== undefined) {
                if (force === 'false') return false;
                if (force === 'true' || force === '') return true;
                var n = Number(force);
                if (!isNaN(n)) return n === 0 ? false : (count === undefined || count <= n);
            }
            if (env.NO_COLOR !== undefined) return false;
            if (!w.isTTY) return false;
            var term = String(env.TERM || '');
            return term !== 'dumb' && term !== '';
        };
        return w;
    }
    processObj.stdout = fdWritable(1);
    processObj.stderr = fdWritable(2);

    var stdinStream = new Readable();
    stdinStream.fd = 0;
    stdinStream.isTTY = __djs.stdio.isTTY() === 1;
    stdinStream._nativeStarted = false;
    stdinStream.resume = function () {
        if (!this._nativeStarted) {
            this._nativeStarted = true;
            var self = this;
            __djs.stdio.stdinStart(function (err, chunk) {
                if (chunk === null) {
                    self._nativeStarted = false;
                    self.push(null);
                } else {
                    self.push(Buffer.from(chunk));
                }
            });
        }
        return Readable.prototype.resume.call(this);
    };
    stdinStream.pause = function () {
        if (this._nativeStarted) {
            this._nativeStarted = false;
            __djs.stdio.stdinStop();
        }
        return Readable.prototype.pause.call(this);
    };
    processObj.stdin = stdinStream;

    processObj.emitWarning = function (warning, type, code) {
        var err = warning instanceof Error ? warning : new Error(String(warning));
        var name = 'Warning';
        if (typeof type === 'string') {
            name = type;
            if (code !== undefined) err.code = String(code);
        } else if (type && typeof type === 'object') {
            if (type.type) name = type.type;
            if (type.code !== undefined) err.code = type.code;
        }
        err.name = name;
        if (processEvents.warning.length) {
            var list = processEvents.warning.slice();
            for (var i = 0; i < list.length; i++) list[i](err);
            return;
        }
        try { processObj.stderr.write(name + ': ' + err.message + '\n'); } catch (e) { }
    };
    var signalHandlers = {};
    var signalNumbers = {
        SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGUSR1: 10,
        SIGUSR2: 12, SIGTERM: 15, SIGWINCH: 28
    };
    function dispatchSignal(signum) {
        var list = (signalHandlers[signum] || []).slice();
        for (var i = 0; i < list.length; i++) list[i](signum);
    }
    // Like Node's process, which is an EventEmitter: any name is accepted, and
    // only the signal names get a native watcher. Registering a listener must
    // never throw — CLIs install 'exit', 'uncaughtException' and
    // 'unhandledRejection' at startup.
    var processEvents = {
        exit: [], beforeExit: [], uncaughtException: [],
        unhandledRejection: [], rejectionHandled: [], warning: [], message: [],
        connect: [], disconnect: [],
    };
    function eventList(name) {
        var key = String(name);
        if (!Object.prototype.hasOwnProperty.call(processEvents, key))
            processEvents[key] = [];
        return processEvents[key];
    }
    processObj.on = function (name, fn) {
        if (typeof fn !== 'function') throw new TypeError('listener must be a function');
        name = String(name);
        if (Object.prototype.hasOwnProperty.call(signalNumbers, name)) {
            var n = signalNumbers[name];
            var list = signalHandlers[n];
            if (!list) {
                list = signalHandlers[n] = [];
                __djs.signal.on(n, dispatchSignal);
            }
            list.push(fn);
            return processObj;
        }
        eventList(name).push(fn);
        return processObj;
    };
    processObj.once = function (name, fn) {
        var wrapped = function () { processObj.off(name, wrapped); return fn.apply(processObj, arguments); };
        return processObj.on(name, wrapped);
    };
    processObj.off = processObj.removeListener = function (name, fn) {
        name = String(name);
        if (Object.prototype.hasOwnProperty.call(signalNumbers, name)) {
            var n = signalNumbers[name];
            var list = signalHandlers[n];
            if (!list) return processObj;
            var i = list.lastIndexOf(fn);
            if (i >= 0) list.splice(i, 1);
            if (list.length === 0) {
                delete signalHandlers[n];
                __djs.signal.off(n);
            }
            return processObj;
        }
        var events = eventList(name);
        var j = events.lastIndexOf(fn);
        if (j >= 0) events.splice(j, 1);
        return processObj;
    };
    processObj.removeAllListeners = function (name) {
        if (name === undefined) {
            for (var k in signalHandlers) __djs.signal.off(Number(k));
            signalHandlers = {};
            for (var ek in processEvents) processEvents[ek] = [];
        } else {
            name = String(name);
            if (Object.prototype.hasOwnProperty.call(signalNumbers, name)) {
                delete signalHandlers[signalNumbers[name]];
                __djs.signal.off(signalNumbers[name]);
            } else {
                processEvents[name] = [];
            }
        }
        return processObj;
    };
    processObj.listeners = function (name) {
        name = String(name);
        if (Object.prototype.hasOwnProperty.call(signalNumbers, name))
            return (signalHandlers[signalNumbers[name]] || []).slice();
        return eventList(name).slice();
    };
    processObj.listenerCount = function (name) {
        return processObj.listeners(name).length;
    };
    // Runs the listeners for an event the engine raises (exit, beforeExit,
    // unhandledRejection, rejectionHandled). Returns how many ran. A throwing
    // listener is reported and does not stop the rest, matching Node's
    // behaviour for 'exit'.
    function emitProcessEvent(name, a, b) {
        var list = (processEvents[name] || []).slice();
        var ran = 0;
        for (var i = 0; i < list.length; i++) {
            ran++;
            try { list[i](a, b); }
            catch (e) {
                try { processObj.stderr.write('Uncaught ' + (e && e.stack ? e.stack : e) + '\n'); } catch (ignored) { }
            }
        }
        return ran;
    }
    // Engine hook: 'exit' and 'beforeExit' take the code, the rejection events
    // take (reason, promise). Returns true when a rejection was handled.
    g.__djsEmitProcessEvent = function (name, a, b) {
        var ran = emitProcessEvent(name, a, b);
        if (name === 'unhandledRejection') return ran > 0;
        return true;
    };
    // Engine hook: the runtime only retains a reported rejection while a
    // 'rejectionHandled' listener exists to observe it.
    g.__djsHasProcessListeners = function (name) {
        return !!(processEvents[name] && processEvents[name].length);
    };
    function emitIpc(type, value) {
        var list = (processEvents[type] || []).slice();
        for (var i = 0; i < list.length; i++) list[i](value);
    }

    var ipcArg = null;
    for (var ai = 0; ai < processObj.argv.length; ai++) {
        if (String(processObj.argv[ai]).indexOf('--djs-ipc=') === 0) ipcArg = String(processObj.argv[ai]).slice(10);
    }
    var ipcPort = processObj.env.DJS_IPC_PORT ? Number(processObj.env.DJS_IPC_PORT) : 0;
    var ipcToken = processObj.env.DJS_IPC_TOKEN || '';
    if (ipcArg) {
        var ipcParts = ipcArg.split(':');
        ipcPort = Number(ipcParts[0]);
        ipcToken = ipcParts[1];
    }
    if (ipcPort) {
        var ipcSock = null, ipcReady = false, ipcQueue = [], ipcBuf = "";
        processObj.connected = false;
        processObj.send = function (message, cb) {
            var line = JSON.stringify(message) + '\n';
            if (ipcReady && ipcSock) ipcSock.write(line);
            else ipcQueue.push(line);
            if (cb) queueMicrotask(function () { cb(null); });
            return true;
        };
        processObj.disconnect = function () {
            if (ipcSock) { ipcSock.end(); ipcSock = null; ipcReady = false; processObj.connected = false; }
        };
        var connectIpc = function (attempt) {
            ipcSock = netModule.connect(ipcPort, '127.0.0.1');
            ipcSock.on('connect', function () {
                ipcReady = true;
                processObj.connected = true;
                ipcSock.write(JSON.stringify({ token: ipcToken }) + '\n');
                while (ipcQueue.length) ipcSock.write(ipcQueue.shift());
                emitIpc('connect', null);
            });
            ipcSock.on('data', function (chunk) {
                ipcBuf += chunk.toString('utf8');
                var idx;
                while ((idx = ipcBuf.indexOf('\n')) >= 0) {
                    var line = ipcBuf.slice(0, idx);
                    ipcBuf = ipcBuf.slice(idx + 1);
                    if (!line) continue;
                    var msg;
                    try { msg = JSON.parse(line); } catch (e) { continue; }
                    emitIpc('message', msg);
                }
            });
            ipcSock.on('close', function () {
                if (!ipcReady) return;
                ipcReady = false;
                processObj.connected = false;
                emitIpc('disconnect', null);
            });
            ipcSock.on('error', function () {
                if (!ipcReady && attempt < 40) setTimeout(function () { connectIpc(attempt + 1); }, 50);
            });
        };
        connectIpc(0);
    }

    function ClusterWorker(id, cp) {
        EventEmitter.call(this);
        this.id = id;
        this.process = cp;
        var self = this;
        cp.on('message', function (m) { self.emit('message', m); });
        cp.on('exit', function (code, signal) {
            self.emit('exit', code, signal);
            delete clusterModule.workers[id];
            clusterModule.emit('exit', self, code, signal);
        });
        cp.on('error', function (e) { self.emit('error', e); });
    }
    ClusterWorker.prototype = Object.create(EventEmitter.prototype);
    ClusterWorker.prototype.constructor = ClusterWorker;
    ClusterWorker.prototype.send = function (message, cb) { return this.process.send(message, cb); };
    ClusterWorker.prototype.kill = function (signal) { return this.process.kill(signal); };
    ClusterWorker.prototype.disconnect = function () { return this.process.disconnect(); };

    var clusterModule = new EventEmitter();
    clusterModule.isPrimary = clusterModule.isMaster = !processObj.env.DJS_CLUSTER_WORKER;
    clusterModule.isWorker = !clusterModule.isPrimary;
    clusterModule.workers = {};
    clusterModule.settings = { execArgv: [], args: [] };
    var nextWorkerId = 1;
    clusterModule.fork = function (env) {
        if (!clusterModule.isPrimary)
            throw new Error('cluster.fork() cannot be called from a worker');
        var id = nextWorkerId++;
        var childEnv = {};
        for (var k in processObj.env) childEnv[k] = processObj.env[k];
        childEnv.DJS_CLUSTER_WORKER = '1';
        childEnv.DJS_CLUSTER_ID = String(id);
        if (env) for (var ek in env) childEnv[ek] = env[ek];
        var cp = childProcessModule.fork(processObj.argv[1] || processObj.argv[0], [], { env: childEnv });
        var worker = new ClusterWorker(id, cp);
        clusterModule.workers[id] = worker;
        clusterModule.emit('fork', worker);
        clusterModule.emit('online', worker);
        return worker;
    };
    clusterModule.disconnect = function (cb) {
        var pending = Object.keys(clusterModule.workers).length;
        if (!pending) { if (cb) cb(); return; }
        for (var id in clusterModule.workers) {
            var w = clusterModule.workers[id];
            w.once('exit', function () { pending -= 1; if (pending === 0 && cb) cb(); });
            w.disconnect();
        }
    };
    if (clusterModule.isWorker) {
        var workerId = Number(processObj.env.DJS_CLUSTER_ID) || 1;
        clusterModule.worker = {
            id: workerId,
            process: processObj,
            send: function (message, cb) { return processObj.send(message, cb); },
            disconnect: function () { processObj.disconnect(); },
            kill: function (signal) { return processObj.kill(processObj.pid, signal); }
        };
    }
    g.cluster = clusterModule;

    // ---- worker_threads (child-process backed) -------------------------
    function WorkerThread(filename, options) {
        EventEmitter.call(this);
        options = options || {};
        var self = this;
        this.threadId = ++nextWorkerThreadId;
        this.workerData = options.workerData;
        this.resourceLimits = {};
        this.stdout = null;
        this.stderr = null;
        var env = {};
        for (var k in processObj.env) env[k] = processObj.env[k];
        if (options.env) for (var ek in options.env) env[ek] = options.env[ek];
        env.DJS_WORKER_THREAD = String(this.threadId);
        env.DJS_WORKER_DATA = options.workerData === undefined ? '' : JSON.stringify(options.workerData);
        var entry = String(filename);
        var tempFile = null;
        if (options.eval) {
            tempFile = (processObj.env.TMPDIR || '/tmp') + '/djs-worker-' + processObj.pid + '-' + this.threadId + '.js';
            fsObj.writeFileSync(tempFile, entry);
            entry = tempFile;
        }
        var cp = childProcessModule.fork(entry, [], { env: env });
        this._cp = cp;
        this._tempFile = tempFile;
        this.stdout = cp.stdout;
        this.stderr = cp.stderr;
        cp.on('message', function (m) { self.emit('message', m); });
        cp.on('error', function (e) { self.emit('error', e); });
        cp.on('exit', function (code) {
            if (self._tempFile) { try { fsObj.unlinkSync(self._tempFile); } catch (e) {} self._tempFile = null; }
            self.emit('exit', code);
        });
    }
    WorkerThread.prototype = Object.create(EventEmitter.prototype);
    WorkerThread.prototype.constructor = WorkerThread;
    WorkerThread.prototype.postMessage = function (value) { return this._cp.send(value); };
    WorkerThread.prototype.terminate = function () {
        var self = this;
        return new Promise(function (resolve) {
            self.once('exit', function (code) { resolve(code === undefined ? 0 : code); });
            self._cp.kill();
        });
    };
    WorkerThread.prototype.ref = function () { return this; };
    WorkerThread.prototype.unref = function () { return this; };

    function WorkerMessagePort() {
        EventEmitter.call(this);
        this._peer = null;
    }
    WorkerMessagePort.prototype = Object.create(EventEmitter.prototype);
    WorkerMessagePort.prototype.constructor = WorkerMessagePort;
    WorkerMessagePort.prototype.postMessage = function (value) {
        var peer = this._peer;
        if (peer) queueMicrotask(function () { peer.emit('message', value); });
    };
    WorkerMessagePort.prototype.start = function () {};
    WorkerMessagePort.prototype.close = function () {};
    function WorkerMessageChannel() {
        this.port1 = new WorkerMessagePort();
        this.port2 = new WorkerMessagePort();
        this.port1._peer = this.port2;
        this.port2._peer = this.port1;
    }

    var workerThreadId = Number(processObj.env.DJS_WORKER_THREAD) || 0;
    var workerData = null;
    if (processObj.env.DJS_WORKER_DATA) {
        try { workerData = JSON.parse(processObj.env.DJS_WORKER_DATA); } catch (e) { workerData = null; }
    }
    var parentPort = null;
    if (workerThreadId) {
        parentPort = new WorkerMessagePort();
        parentPort.postMessage = function (value) { return processObj.send(value); };
        processObj.on('message', function (m) { parentPort.emit('message', m); });
    }
    g.worker_threads = {
        isMainThread: !workerThreadId,
        threadId: workerThreadId,
        workerData: workerData,
        parentPort: parentPort,
        Worker: WorkerThread,
        MessagePort: WorkerMessagePort,
        MessageChannel: WorkerMessageChannel
    };
    var nextWorkerThreadId = 0;

    processObj.execPath = __djs.process.execPath();
    processObj.pid = __djs.process.pid();
    processObj.ppid = __djs.process.ppid();
    var processTitle = processObj.argv[1] || 'djs';
    Object.defineProperty(processObj, 'title', {
        get: function () { return processTitle; },
        set: function (value) { processTitle = String(value); },
        enumerable: true
    });
    processObj.argv0 = processObj.execPath;
    var exitCodeValue;
    Object.defineProperty(processObj, 'exitCode', {
        get: function () { return exitCodeValue; },
        set: function (value) {
            if (value === undefined || value === null) {
                exitCodeValue = undefined;
                __djs.process.setExitCode(0);
                return;
            }
            var n = Number(value);
            exitCodeValue = n;
            __djs.process.setExitCode(n);
        },
        enumerable: true,
        configurable: true
    });
    if (processObj.stdin) {
        processObj.stdin.isTTY = __djs.stdio.isattyFd(0) === 1;
        // Raw mode needs termios; until then interactive prompts fall back to
        // line-buffered input instead of crashing on the missing method.
        processObj.stdin.setRawMode = function () { return processObj.stdin; };
        processObj.stdin.setEncoding = processObj.stdin.setEncoding;
    }
    g.process = processObj;
    fsObj.statfsSync = function (path) { return __djs.fs.statfsSync(path); };
    fsObj.statfs = function (path, options, cb) {
        if (typeof options === 'function') { cb = options; options = undefined; }
        queueMicrotask(function () {
            try { cb(null, __djs.fs.statfsSync(path)); }
            catch (e) { cb(e); }
        });
    };
    function globToRegExp(pattern) {
        var re = '^';
        for (var i = 0; i < pattern.length; i++) {
            var ch = pattern[i];
            if (ch === '*') {
                if (pattern[i + 1] === '*') {
                    i += 1;
                    if (pattern[i + 1] === '/') { i += 1; re += '(?:.*/)?'; }
                    else re += '.*';
                } else re += '[^/]*';
            } else if (ch === '?') re += '[^/]';
            else if ('\\^$.|+()[]{}'.indexOf(ch) >= 0) re += '\\' + ch;
            else re += ch;
        }
        return new RegExp(re + '$');
    }
    fsObj.globSync = function (pattern, options) {
        options = options || {};
        var cwd = options.cwd || process.cwd();
        var re = globToRegExp(String(pattern));
        var out = [];
        (function walk(dir, rel) {
            var names;
            try { names = fsObj.readdirSync(dir); } catch (e) { return; }
            for (var i = 0; i < names.length; i++) {
                var name = names[i];
                var relPath = rel ? rel + '/' + name : name;
                var full = pathModule.join(dir, name);
                var st;
                try { st = fsObj.statSync(full); } catch (e) { continue; }
                if (re.test(relPath)) out.push(relPath);
                if (st.isDirectory()) walk(full, relPath);
            }
        })(cwd, '');
        out.sort();
        return out;
    };
    fsObj.glob = function (pattern, options, cb) {
        if (typeof options === 'function') { cb = options; options = {}; }
        queueMicrotask(function () {
            try { cb(null, fsObj.globSync(pattern, options)); } catch (e) { cb(e); }
        });
    };

    // Promise-namespace forms of the late-bound fs additions; fsPromises lives in
    // 02-fs.js, so they are attached here where statfs/opendir/glob exist.
    fsObj.promises.statfs = function (path) {
        return new Promise(function (resolve, reject) {
            fsObj.statfs(path, {}, function (err, st) { if (err) reject(err); else resolve(st); });
        });
    };
    fsObj.promises.opendir = function (path, options) {
        return new Promise(function (resolve, reject) {
            fsObj.opendir(path, options || {}, function (err, dir) { if (err) reject(err); else resolve(dir); });
        });
    };
    fsObj.promises.glob = function (pattern, options) {
        return new Promise(function (resolve, reject) {
            fsObj.glob(pattern, options || {}, function (err, matches) { if (err) reject(err); else resolve(matches); });
        });
    };

    g.fs = fsObj;
    g.Buffer = Buffer;
    g.path = pathModule;
    function osConst(name) { return function () { const v = __djs.os[name]; return typeof v === 'function' ? v() : v; }; }
    g.os = {
        platform: osConst('platform'),
        arch: osConst('arch'),
        type: osConst('type'),
        release: osConst('release'),
        hostname: osConst('hostname'),
        tmpdir: osConst('tmpdir'),
        homedir: osConst('homedir'),
        EOL: __djs.os.eol,
        eol: __djs.os.eol,
        devNull: __djs.os.devNull,
        endianness: osConst('endianness'),
        cpus: __djs.os.cpus,
        totalmem: __djs.os.totalmem,
        freemem: __djs.os.freemem,
        uptime: __djs.os.uptime,
        loadavg: __djs.os.loadavg,
        networkInterfaces: __djs.os.networkInterfaces,
        userInfo: __djs.os.userInfo,
        availableParallelism: function () { return g.os.cpus().length; },
        machine: osConst('arch') === 'x64' ? 'x86_64' : osConst('arch'),
        constants: {
            signals: {
                SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGTERM: 15,
                SIGUSR1: 10, SIGUSR2: 12, SIGPIPE: 13, SIGALRM: 14,
                SIGCHLD: 17, SIGCONT: 18, SIGSTOP: 19
            },
            errno: {}
        }
    };
    function vmWrapper(code) {
        return "(function(__sandbox){with(__sandbox){return eval(" + JSON.stringify(String(code)) + ");}})";
    }
    function VmScript(code, options) {
        this.code = String(code);
        this.filename = (options && options.filename) || 'evalmachine.<anonymous>';
    }
    VmScript.prototype.runInThisContext = function () {
        return __djs.vm.runThis(this.code, this.filename);
    };
    VmScript.prototype.runInNewContext = function (sandbox, options) {
        var json = JSON.stringify(sandbox || {});
        var r = __djs.vm.runNew(vmWrapper(this.code), json, (options && options.filename) || this.filename);
        return r === undefined ? undefined : JSON.parse(r);
    };
    g.vm = {
        Script: VmScript,
        createContext: function (sandbox) { return sandbox || {}; },
        isContext: function (v) { return v !== null && typeof v === 'object'; },
        runInThisContext: function (code, options) {
            return __djs.vm.runThis(String(code), (options && options.filename) || 'evalmachine.<anonymous>');
        },
        runInNewContext: function (code, sandbox, options) {
            var s = new VmScript(code, options);
            return s.runInNewContext(sandbox, options);
        },
        runInContext: function (code, context, options) {
            var s = new VmScript(code, options);
            return s.runInNewContext(context, options);
        }
    };
    // ---- diagnostics_channel -------------------------------------------
    var dcChannels = Object.create(null);
    function DcChannel(name) {
        this.name = String(name);
        this._subs = [];
    }
    Object.defineProperty(DcChannel.prototype, 'hasSubscribers', {
        get: function () { return this._subs.length > 0; }
    });
    DcChannel.prototype.subscribe = function (fn) {
        if (typeof fn !== 'function') throw new TypeError('listener must be a function');
        if (this._subs.indexOf(fn) < 0) this._subs.push(fn);
        return this;
    };
    DcChannel.prototype.unsubscribe = function (fn) {
        var i = this._subs.indexOf(fn);
        if (i >= 0) this._subs.splice(i, 1);
        return this;
    };
    DcChannel.prototype.publish = function (message) {
        var list = this._subs.slice();
        for (var i = 0; i < list.length; i++) list[i](message);
    };
    function dcChannel(name) {
        var key = String(name);
        var ch = dcChannels[key];
        if (!ch) ch = dcChannels[key] = new DcChannel(key);
        return ch;
    }
    var diagnosticsChannel = {
        Channel: DcChannel,
        channel: dcChannel,
        hasSubscribers: function (name) { return dcChannel(name).hasSubscribers; },
        subscribe: function (name, fn) { dcChannel(name).subscribe(fn); },
        unsubscribe: function (name, fn) { dcChannel(name).unsubscribe(fn); }
    };
    g.diagnostics_channel = diagnosticsChannel;

    g.trace_events = {
        createTracing: function (options) {
            return { enabled: false, categories: (options && options.categories) || [] };
        },
        getEnabledCategories: function () { return undefined; }
    };

    // ---- perf_hooks marks/measures -------------------------------------
    var perfEntries = [];
    performance.mark = function (name, options) {
        var entry = { name: String(name), entryType: 'mark', startTime: performance.now(), duration: 0, detail: options && options.detail };
        perfEntries.push(entry);
        return entry;
    };
    function perfTime(ref) {
        if (typeof ref === 'number') return ref;
        if (ref && typeof ref === 'object' && typeof ref.startTime === 'number') return ref.startTime;
        var name = String(ref);
        for (var i = perfEntries.length - 1; i >= 0; i--) {
            if (perfEntries[i].entryType === 'mark' && perfEntries[i].name === name) return perfEntries[i].startTime;
        }
        throw new Error('Unknown mark: ' + name);
    }
    performance.measure = function (name, start, end) {
        var st = start === undefined ? 0 : perfTime(start);
        var en = end === undefined ? performance.now() : perfTime(end);
        var entry = { name: String(name), entryType: 'measure', startTime: st, duration: en - st, detail: undefined };
        perfEntries.push(entry);
        return entry;
    };
    performance.getEntries = function () { return perfEntries.slice(); };
    performance.getEntriesByType = function (type) {
        return perfEntries.filter(function (e) { return e.entryType === type; });
    };
    performance.getEntriesByName = function (name, type) {
        return perfEntries.filter(function (e) { return e.name === name && (type === undefined || e.entryType === type); });
    };
    performance.clearMarks = function (name) {
        perfEntries = perfEntries.filter(function (e) { return e.entryType !== 'mark' || (name !== undefined && e.name !== name); });
    };
    performance.clearMeasures = function (name) {
        perfEntries = perfEntries.filter(function (e) { return e.entryType !== 'measure' || (name !== undefined && e.name !== name); });
    };
    function PerformanceObserver(callback) {
        this._callback = callback;
        this._types = [];
    }
    PerformanceObserver.prototype.observe = function (options) {
        this._types = (options && (options.entryTypes || (options.type ? [options.type] : []))) || [];
    };
    PerformanceObserver.prototype.disconnect = function () { this._types = []; };
    PerformanceObserver.prototype.takeRecords = function () { return []; };
    g.perf_hooks = {
        performance: performance,
        PerformanceObserver: PerformanceObserver
    };

    // ---- EventSource (SSE) ---------------------------------------------
    function EventSource(url, options) {
        this.url = String(url);
        this.withCredentials = !!(options && options.withCredentials);
        this.readyState = 0;
        this.onopen = null;
        this.onmessage = null;
        this.onerror = null;
        this._listeners = Object.create(null);
        this._closed = false;
        this._req = null;
        this._retry = 3000;
        this._origin = '';
        var parsed = new URL(this.url);
        this._origin = parsed.protocol + '//' + parsed.host;
        var self = this;
        function start() {
            if (self._closed) return;
            var mod = parsed.protocol === 'https:' ? httpsModule : httpModule;
            var req = mod.get(self.url, { headers: { accept: 'text/event-stream', 'cache-control': 'no-cache' } }, function (res) {
                var ct = String(res.headers['content-type'] || '');
                if (res.statusCode !== 200 || ct.indexOf('text/event-stream') < 0) {
                    res.destroy();
                    self._reconnect();
                    return;
                }
                self.readyState = 1;
                self._emit('open', { type: 'open' });
                var buf = '', data = [], eventName = 'message', lastId = '';
                res.on('data', function (chunk) {
                    buf += chunk.toString('utf8');
                    var idx;
                    while ((idx = buf.indexOf('\n')) >= 0) {
                        var line = buf.slice(0, idx);
                        buf = buf.slice(idx + 1);
                        if (line.length && line.charCodeAt(line.length - 1) === 13) line = line.slice(0, -1);
                        if (line === '') {
                            if (data.length) {
                                self._emit(eventName, {
                                    type: eventName,
                                    data: data.join('\n'),
                                    lastEventId: lastId,
                                    origin: self._origin
                                });
                            }
                            data = [];
                            eventName = 'message';
                            continue;
                        }
                        if (line.charCodeAt(0) === 58) continue;
                        var colon = line.indexOf(':');
                        var field = colon < 0 ? line : line.slice(0, colon);
                        var value = colon < 0 ? '' : line.slice(colon + 1);
                        if (value.charCodeAt(0) === 32) value = value.slice(1);
                        if (field === 'data') data.push(value);
                        else if (field === 'event') eventName = value || 'message';
                        else if (field === 'id') lastId = value;
                        else if (field === 'retry') { var r = Number(value); if (r === r && r >= 0) self._retry = r; }
                    }
                });
                res.on('end', function () { if (!self._closed) self._reconnect(); });
                res.on('error', function () { if (!self._closed) self._reconnect(); });
            });
            req.on('error', function () { if (!self._closed) self._reconnect(); });
            self._req = req;
        }
        this._start = start;
        start();
    }
    EventSource.prototype._emit = function (type, event) {
        var list = this._listeners[type];
        if (list) {
            list = list.slice();
            for (var i = 0; i < list.length; i++) list[i].call(this, event);
        }
        var prop = this['on' + type];
        if (typeof prop === 'function') prop.call(this, event);
        if (!event.target) event.target = this;
    };
    EventSource.prototype.addEventListener = function (type, fn) {
        if (typeof fn !== 'function') return;
        var list = this._listeners[type];
        if (!list) list = this._listeners[type] = [];
        list.push(fn);
    };
    EventSource.prototype.removeEventListener = function (type, fn) {
        var list = this._listeners[type];
        if (!list) return;
        var i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
    };
    EventSource.prototype._reconnect = function () {
        if (this._closed) return;
        var self = this;
        this.readyState = 0;
        this._emit('error', { type: 'error', message: 'connection lost' });
        setTimeout(function () { self._start(); }, this._retry);
    };
    EventSource.prototype.close = function () {
        this._closed = true;
        this.readyState = 2;
        if (this._req) { this._req.abort(); this._req = null; }
    };
    EventSource.CONNECTING = 0;
    EventSource.OPEN = 1;
    EventSource.CLOSED = 2;
    g.EventSource = EventSource;

    g.Stats = Stats;
})(globalThis);
