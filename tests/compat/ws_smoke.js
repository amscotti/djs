const http = require("http");
const { WebSocketServer, WebSocket } = require("ws");

const server = http.createServer(function (req, res) { res.end("ok"); });
const wss = new WebSocketServer({ server: server });
wss.on("connection", function (socket) {
    socket.on("message", function (data) { socket.send("echo:" + data.toString()); });
});

server.listen(0, "127.0.0.1", function () {
    const client = new WebSocket("ws://127.0.0.1:" + server.address().port);
    const timer = setTimeout(function () { console.log("timeout"); process.exit(1); }, 5000);
    client.on("open", function () { client.send("hello"); });
    client.on("message", function (data) {
        console.log("ws", data.toString());
        clearTimeout(timer);
        client.close();
        wss.close();
        server.close();
    });
    client.on("error", function (e) { console.log("ws-error", e.message); process.exit(1); });
});
