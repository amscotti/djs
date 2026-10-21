const net = require("net");

const server = net.createServer(function (socket) {
    socket.on("data", function (d) {
        socket.write("echo:" + d.toString());
        socket.end();
    });
});

server.listen(0, "127.0.0.1", function () {
    const port = server.address().port;
    console.log("listen", port > 0);
    const client = net.connect(port, "127.0.0.1", function () {
        client.write("hello");
    });
    const chunks = [];
    client.on("data", d => chunks.push(d));
    client.on("end", function () {
        console.log("reply", Buffer.concat(chunks).toString());
        server.close(function () { console.log("closed"); });
    });
});
