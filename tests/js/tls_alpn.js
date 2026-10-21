const tls = require("tls");
const dir = "tests/js/fixtures/tls/";
const server = tls.createServer({
    cert: dir + "server.pem", key: dir + "server.key", alpn: "h2,http/1.1"
}, function (sock) {
    console.log("server-alpn", sock.alpnProtocol);
    sock.end("alpn-ok");
});
server.listen(0, "127.0.0.1", function () {
    const c = tls.connect({
        port: server.address().port, host: "127.0.0.1", servername: "localhost",
        caFile: dir + "ca.pem", alpn: "http/1.1,h2"
    }, function () {
        console.log("client-alpn", c.alpnProtocol);
    });
    let body = "";
    c.on("data", function (d) { body += d.toString(); });
    c.on("end", function () { console.log("body", body); server.close(); });
});
