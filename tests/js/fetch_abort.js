// fetch() must honour AbortSignal: an already-aborted signal rejects with
// AbortError and no request is made; aborting mid-flight tears the socket
// down and rejects instead of hanging.
const net = require('net');

// A server that accepts and never answers.
const server = net.createServer(function (sock) {
    sock.on('error', function () {});
});
server.listen(0, '127.0.0.1', function () {
    const port = server.address().port;
    const url = 'http://127.0.0.1:' + port + '/hang';

    // 1. Pre-aborted: rejects immediately, name === 'AbortError'.
    const c1 = new AbortController();
    c1.abort();
    fetch(url, { signal: c1.signal })
        .then(function () { console.log('pre-aborted resolved (bad)'); startMid(); })
        .catch(function (e) { console.log('pre-aborted', e.name); startMid(); });

    var started = false;
    function startMid() {
        if (started) return;
        started = true;
        // 2. Abort mid-flight while the server stalls.
        const c2 = new AbortController();
        fetch(url, { signal: c2.signal })
            .then(function () { console.log('mid-abort resolved (bad)'); finish(); })
            .catch(function (e) { console.log('mid-abort', e.name); finish(); });
        setTimeout(function () { c2.abort(); }, 50);
    }

    function finish() {
        server.close(function () { console.log('done'); });
    }
});
