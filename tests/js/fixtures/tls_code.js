const port = Number(process.argv[2]);
require("https").get("https://127.0.0.1:" + port + "/", function (res) {
    console.log("code ok", res.statusCode);
}).on("error", e => console.log("code", e.code));
