const http = require("http");
const net = require("net");

const server = http.createServer();
server.on("upgrade", function (req, socket) {
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: test\r\nConnection: Upgrade\r\n\r\n");
    console.log("upgraded", true);
    server.close(function () {
        console.log("close-callback", true);
        socket.destroy();
    });
});
server.listen(0, "127.0.0.1", function () {
    const client = net.connect(server.address().port, "127.0.0.1", function () {
        client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\n");
    });
    client.on("data", function () {});
    setTimeout(function () { process.exit(0); }, 500);
});
