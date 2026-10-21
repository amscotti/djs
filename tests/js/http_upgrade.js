const http = require("http");
const net = require("net");

const server = http.createServer(function (req, res) { res.end("normal"); });
server.on("upgrade", function (req, socket, head) {
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: test\r\nConnection: Upgrade\r\n\r\n");
    console.log("upgrade", req.headers.upgrade, JSON.stringify(head.toString()));
    if (head.length) socket.write(head);
    socket.on("data", function (d) { socket.write(d); });
});

server.listen(0, "127.0.0.1", function () {
    const socket = net.connect(server.address().port, "127.0.0.1", function () {
        socket.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\nping");
    });
    let out = "";
    let sent = false;
    socket.on("data", function (d) {
        out += d.toString();
        if (!sent && out.indexOf("101 Switching Protocols") !== -1) {
            sent = true;
            socket.write("pong");
        }
    });
    setTimeout(function () {
        console.log("status", out.indexOf("101 Switching Protocols") !== -1);
        console.log("echo", out.indexOf("pingpong") !== -1);
        socket.destroy();
        server.close();
    }, 400);
});
