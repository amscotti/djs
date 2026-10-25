// Parser hardening: a truncated chunked response is an error, not a
// complete body; a request carrying both Transfer-Encoding and
// Content-Length is destroyed (the request-smuggling shape).
const net = require('net');
const http = require('http');

// 1. Client receives a chunked body that dies mid-chunk.
const evil = net.createServer(function (sock) {
    sock.on('error', function () {});
    sock.write(Buffer.from(
        'HTTP/1.1 200 OK\r\n' +
        'Transfer-Encoding: chunked\r\n\r\n' +
        '5\r\nhello\r\n' +
        'a\r\nwor', 'latin1'));   // promised 10 bytes, delivers 3, then EOF
    sock.end();
});
evil.listen(0, '127.0.0.1', function () {
    const port = evil.address().port;
    const req = http.get('http://127.0.0.1:' + port + '/', function (res) {
        res.on('data', function () {});
        res.on('end', function () {
            console.log('truncated-end (bad)');
            part2();
        });
        res.on('error', function (e) {
            console.log('truncated-error', e.code);
            part2();
        });
    });
    req.on('error', function (e) {
        console.log('truncated-error', e.code);
        part2();
    });

    var ran2 = false;
    function part2() {
        if (ran2) return;
        ran2 = true;
        evil.close(function () { teCl(); });
    }
});

// 2. Server receives TE + CL: the connection must be destroyed without a
// response (llhttp/Node behaviour), not parsed as either framing.
function teCl() {
    const server = http.createServer(function (req, res) {
        console.log('handler-reached (bad)');
        res.end('no');
    });
    server.listen(0, '127.0.0.1', function () {
        const port = server.address().port;
        const raw = net.connect(port, '127.0.0.1', function () {
            raw.write(Buffer.from(
                'POST / HTTP/1.1\r\n' +
                'Host: x\r\n' +
                'Transfer-Encoding: chunked\r\n' +
                'Content-Length: 5\r\n\r\n' +
                '0\r\n\r\n', 'latin1'));
        });
        raw.on('error', function () {});
        var settled = false;
        var watchdog = null;
        raw.on('close', function () {
            if (settled) return;
            settled = true;
            if (watchdog) clearTimeout(watchdog);
            console.log('te-cl-rejected');
            server.close(function () { console.log('done'); });
        });
        watchdog = setTimeout(function () {
            if (settled) return;
            settled = true;
            console.log('te-cl-timeout (bad)');
            raw.destroy();
            server.close(function () { console.log('done'); });
        }, 500);
    });
}
