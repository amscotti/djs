// Socket-table churn and callback-reentrancy regressions.
//
// 1. Socket ids come from a monotonic counter, so closing must accept any
//    live id: after more connections than the table has slots, every socket
//    must still be closable and the table must keep working. (A close()
//    bounded by the table size strands every later socket.)
// 2. Destroying a socket from inside its own write-completion callback must
//    not crash the poll re-arm path.
const net = require('net');

const server = net.createServer(function (s) {
    s.destroy();
});

server.on('error', function (e) {
    console.log('server error', e.code);
    process.exit(1);
});

server.listen(0, '127.0.0.1', function () {
    const port = server.address().port;
    let n = 0;
    const total = 300;

    function next() {
        if (n >= total) {
            writeDestroy();
            return;
        }
        n += 1;
        const c = net.connect(port, '127.0.0.1', function () {
            c.destroy();
        });
        c.on('error', function (e) {
            console.log('churn error at', n, e.code);
            process.exit(1);
        });
        c.on('close', next);
    }

    function writeDestroy() {
        const c = net.connect(port, '127.0.0.1', function () {
            c.write('x', function () {
                // The write callback re-enters native code through destroy();
                // the poll re-arm after it must notice the closed socket.
                c.destroy();
            });
        });
        c.on('error', function (e) {
            console.log('write-destroy error', e.code);
            process.exit(1);
        });
        c.on('close', function () {
            console.log('churn', total, 'ok');
            console.log('write-destroy ok');
            server.close(function () {
                console.log('server closed ok');
            });
        });
    }

    next();
});
