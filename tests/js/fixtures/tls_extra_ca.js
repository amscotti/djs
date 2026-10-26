const port = Number(process.argv[2]);
require("https").get("https://127.0.0.1:" + port + "/", function (res) {
    let n = 0;
    res.on("data", d => { n += d.length; });
    res.on("end", () => console.log("extra-ca", res.statusCode, n > 0));
}).on("error", e => console.log("extra-ca-err", e.code));
