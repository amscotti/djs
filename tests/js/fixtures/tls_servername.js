const port = Number(process.argv[2]);
const name = process.argv[3] === "-" ? "" : process.argv[3];
const ca = process.argv[4];
const tls = require("tls");
const sock = tls.connect({
    host: "127.0.0.1",
    port: port,
    servername: name,
    caFile: ca
}, function () {
    console.log("servername ok");
    process.exit(0);
});
sock.on("error", function (e) {
    console.log("servername", e.code);
    process.exit(0);
});
