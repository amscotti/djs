// HTTP bodies framed only by connection close must complete on EOF, not be
// mistaken for a reset. Covers plain TCP and TLS (where EOF arrives as close).
const net = require("net");
const tls = require("tls");
const http = require("http");
const https = require("https");
const path = require("path");

const RESPONSE = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";

function plain() {
    return new Promise(function (resolve, reject) {
        const srv = net.createServer(function (sock) {
            sock.once("data", function () { sock.end(RESPONSE + "hello-plain"); });
        });
        srv.listen(0, "127.0.0.1", function () {
            http.get({ port: srv.address().port, host: "127.0.0.1", path: "/" }, function (res) {
                let body = "";
                res.on("data", function (c) { body += c; });
                res.on("end", function () {
                    console.log("plain", res.statusCode, body);
                    srv.close(function () { resolve(); });
                });
            }).on("error", reject);
        });
    });
}

function secure() {
    return new Promise(function (resolve, reject) {
        const dir = path.join(__dirname, "..", "fixtures", "tls");
        const srv = tls.createServer({
            cert: path.join(dir, "cert.pem"),
            key: path.join(dir, "key.pem")
        }, function (sock) {
            sock.once("data", function () { sock.end(RESPONSE + "hello-tls"); });
        });
        srv.listen(0, "127.0.0.1", function () {
            https.get({
                protocol: "https:", port: srv.address().port, host: "127.0.0.1",
                path: "/", rejectUnauthorized: false
            }, function (res) {
                let body = "";
                res.on("data", function (c) { body += c; });
                res.on("end", function () {
                    console.log("tls", res.statusCode, body);
                    srv.close(function () { resolve(); });
                });
            }).on("error", reject);
        });
    });
}

plain().then(secure).catch(function (e) {
    console.log("ERR", e.code || e.message);
    process.exitCode = 1;
});
