const { WebSocketServer, WebSocket } = require("djs:ws");

const server = new WebSocketServer({ port: 0 });
server.on("connection", function (conn) {
    conn.on("message", function (msg) {
        conn.send("echo:" + msg);
    });
});

server._server.on("listening", function () {
    const port = server.address().port;
    const client = new WebSocket("ws://127.0.0.1:" + port + "/chat");
    client.on("error", function (e) { console.log("ERR", e.message); process.exitCode = 1; });
    client.on("open", function () { client.send("hi"); });
    let received = false;
    client.on("message", function (msg) {
        received = true;
        console.log("message", msg);
        client.close();
    });
    client.on("close", function (code) {
        console.log("close", code);
        server.close();
    });
    const timer = setTimeout(function () {
        if (!received) {
            console.log("timeout");
            process.exitCode = 1;
            server.close();
        }
    }, 2000);
    if (timer.unref) timer.unref();
});
