const https = require("https");
const fs = require("fs");
const path = require("path");

const dir = path.join(__dirname, "..", "fixtures", "tls");
const srv = https.createServer({
    cert: path.join(dir, "cert.pem"),
    key: path.join(dir, "key.pem")
}, function (req, res) {
    res.end("secure:" + req.url);
});

srv.listen(0, "127.0.0.1", function () {
    const port = srv.address().port;
    https.get("https://127.0.0.1:" + port + "/hello", { rejectUnauthorized: false }, function (res) {
        const chunks = [];
        res.on("data", function (c) { chunks.push(c); });
        res.on("end", function () {
            console.log("https-server", res.statusCode, Buffer.concat(chunks).toString());
            srv.close();
        });
    }).on("error", function (e) {
        console.log("ERR", e.code || e.message);
        process.exitCode = 1;
    });
});
