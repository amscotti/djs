// A malformed HTTP/2 frame (bad HPACK index) must destroy the session,
// never the process. Before the fix the throw escaped into the native read
// callback and became an uncaught exception (exit 1) — one TCP peer could
// kill any http2 server or client.
const net = require('net');
const http2 = require('http2');

function frame(type, flags, id, payload) {
    const h = Buffer.alloc(9);
    h[0] = (payload.length >> 16) & 255;
    h[1] = (payload.length >> 8) & 255;
    h[2] = payload.length & 255;
    h[3] = type;
    h[4] = flags;
    h.writeUInt32BE(id & 0x7fffffff, 5);
    return Buffer.concat([h, payload]);
}

// 1. Client side: a hostile server sends a HEADERS frame with an
// out-of-range HPACK index (0xFF starts a 7-bit-prefix integer continuation).
const evil = net.createServer(function (sock) {
    sock.on('error', function () {});
    sock.write(frame(4, 0, 0, Buffer.alloc(0))); // SETTINGS
    sock.write(frame(1, 0x4, 1, Buffer.from([0xff, 0x9f, 0xaf, 0xff, 0x7f])));
});
evil.listen(0, '127.0.0.1', function () {
    const session = http2.connect('http://127.0.0.1:' + evil.address().port);
    session.on('error', function (e) {
        console.log('client-session-error', e.message.slice(0, 20));
    });
    session.on('close', function () {
        console.log('client-session-closed');
        evil.close(function () { serverSide(); });
    });
});

// 2. Server side: a hostile client does the same to an http2 server.
function serverSide() {
    const server = http2.createServer();
    server.on('stream', function (stream) {
        stream.respond({ ':status': 200 });
        stream.end('ok');
    });
    server.listen(0, '127.0.0.1', function () {
        const port = server.address().port;
        const raw = net.connect(port, '127.0.0.1', function () {
            const preface = Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n');
            raw.write(preface);
            raw.write(frame(4, 0, 0, Buffer.alloc(0)));
            raw.write(frame(1, 0x4, 1, Buffer.from([0xff, 0x9f, 0xaf, 0xff, 0x7f])));
        });
        raw.on('error', function () {});
        raw.on('close', function () {
            console.log('server-survived-close');
            server.close(function () {
                console.log('done');
            });
        });
    });
}
