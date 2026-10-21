const net = require("net");
const dns = require("dns");

dns.lookup("::1", function (err, address, family) {
    console.log("lookup6", err ? err.code : address, family);
    const srv = net.createServer(function (sock) {
        sock.on("data", function (d) { sock.end("v6:" + d.toString()); });
    });
    srv.listen(0, "::1", function () {
        const port = srv.address().port;
        console.log("listen-family", srv.address().family);
        const c = net.connect(port, "::1");
        const chunks = [];
        c.on("data", function (d) { chunks.push(d); });
        c.on("end", function () {
            console.log("ipv6", Buffer.concat(chunks).toString());
            srv.close();
        });
        c.on("connect", function () { c.write("hi"); });
    });
});
