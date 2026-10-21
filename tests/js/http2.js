const http2 = require("http2");

const server = http2.createServer();
server.on("stream", function (stream, headers) {
    console.log("server-stream", headers[":method"], headers[":path"]);
    stream.respond({ ":status": 200, "content-type": "text/plain" });
    stream.end("hello");
});

server.listen(0, "127.0.0.1", function () {
    const session = http2.connect("http://127.0.0.1:" + server.address().port);
    const req = session.request({
        ":method": "GET",
        ":path": "/x",
        ":scheme": "http",
        ":authority": "127.0.0.1"
    });
    const chunks = [];
    req.on("response", function (headers) {
        console.log("client-response", headers[":status"], headers["content-type"]);
    });
    req.on("data", function (d) { chunks.push(d); });
    req.on("end", function () {
        console.log("client-body", Buffer.concat(chunks).toString());
        session.close();
        server.close();
        setTimeout(function () { process.exit(0); }, 50);
    });
    req.on("error", function (e) {
        console.log("stream-error", e.message);
        process.exit(1);
    });
});

const fail = setTimeout(function () {
    console.log("timeout");
    process.exit(1);
}, 3000);
if (fail.unref) fail.unref();
