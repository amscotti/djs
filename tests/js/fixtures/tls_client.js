const port = Number(process.argv[2]);
const https = require("https");

https.get("https://127.0.0.1:" + port + "/", { rejectUnauthorized: false }, function (res) {
    let n = 0;
    res.on("data", d => { n += d.length; });
    res.on("end", () => console.log("https", res.statusCode, n > 0));
}).on("error", e => console.log("https-err", e.code));

https.get("https://127.0.0.1:" + port + "/", function () {
    console.log("verify NO-ERROR");
}).on("error", e => console.log("verify", e.code));

fetch("https://127.0.0.1:" + port + "/", { rejectUnauthorized: false })
    .then(r => r.text())
    .then(t => console.log("fetch", t.length > 0))
    .catch(e => console.log("fetch-err", e.code));
