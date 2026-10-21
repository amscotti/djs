const tls = require("tls");
const dir = "tests/js/fixtures/tls/";
const server = tls.createServer({ cert: dir + "server.pem", key: dir + "server.key" }, function (sock) {
    sock.end("hello");
});
server.listen(0, "127.0.0.1", function () {
    const port = server.address().port;
    const good = tls.connect({ port: port, host: "127.0.0.1", servername: "localhost", caFile: dir + "ca.pem" }, function () {
        console.log("secure", good.authorized);
    });
    let body = "";
    good.on("data", function (d) { body += d.toString(); });
    good.on("end", function () {
        console.log("data", body);
        const bad = tls.connect({ port: port, host: "127.0.0.1", servername: "localhost" });
        bad.on("error", function (e) {
            console.log("untrusted", e.code);
            server.close();
        });
        bad.on("data", function () {});
    });
});
