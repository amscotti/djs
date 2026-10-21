const http2 = require("http2");
const dir = "tests/js/fixtures/tls/";
const server = http2.createSecureServer({
    cert: dir + "server.pem", key: dir + "server.key", alpn: "h2"
});
server.on("stream", function (stream, headers) {
    console.log("server-stream", headers[":method"], headers[":path"]);
    stream.respond({ ":status": 200, "content-type": "text/plain" });
    stream.end("secure-h2");
});
server.listen(0, "127.0.0.1", function () {
    const session = http2.connect("https://localhost:" + server.address().port, { caFile: dir + "ca.pem" });
    session.on("error", function (e) { console.log("session-error", e.code || e.message); });
    const req = session.request({ ":method": "GET", ":path": "/tls" });
    let body = "";
    req.on("data", function (d) { body += d.toString(); });
    req.on("end", function () {
        console.log("client-body", body);
        session.close();
        server.close();
    });
});
