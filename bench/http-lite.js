const http = require("http");

const server = http.createServer(function (req, res) {
    if (req.url === "/json") {
        const body = JSON.stringify({ ok: true, n: 1 });
        res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
        res.end(body);
        return;
    }
    res.writeHead(200, { "content-type": "text/plain", "content-length": 2 });
    res.end("ok");
});

const port = Number(process.env.PORT) || 3000;
server.listen(port, "127.0.0.1", function () {
    console.log("ready " + port);
});
