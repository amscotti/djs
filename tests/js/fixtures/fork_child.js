process.on('message', function (msg) {
    if (msg && msg.type === 'ping') {
        process.send({ type: 'pong', n: msg.n });
        setTimeout(function () { process.exit(0); }, 50);
    }
});
process.send({ type: 'ready' });
