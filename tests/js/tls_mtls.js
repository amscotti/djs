const tls = require("tls");
const dir = "tests/js/fixtures/tls/";
const server = tls.createServer({
    cert: dir + "server.pem", key: dir + "server.key",
    caFile: dir + "ca.pem", requestCert: true
}, function (sock) {
    console.log("server-authorized", sock.authorized);
    sock.end("mtls-ok");
});
server.listen(0, "127.0.0.1", function () {
    const port = server.address().port;
    const good = tls.connect({
        port: port, host: "127.0.0.1", servername: "localhost",
        caFile: dir + "ca.pem", certFile: dir + "client.pem", keyFile: dir + "client.key"
    }, function () { console.log("client-secure", good.authorized); });
    let body = "";
    good.on("data", function (d) { body += d.toString(); });
    good.on("end", function () {
        console.log("body", body);
        server.close();
    });
});
