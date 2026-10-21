const dgram = require("dgram");

const b = dgram.createSocket("udp4");
const a = dgram.createSocket("udp4");

b.on("message", function (msg, rinfo) {
    console.log("server", msg.toString(), rinfo.port > 0);
    b.send("pong", rinfo.port, rinfo.address);
});

b.bind(0, "127.0.0.1", function () {
    const port = b.address().port;
    console.log("bound", port > 0);
    a.on("message", function (msg, rinfo) {
        console.log("client", msg.toString(), rinfo.address === "127.0.0.1");
        a.close();
        b.close();
    });
    a.bind(0, "127.0.0.1", function () {
        a.send("ping", port, "127.0.0.1");
    });
});
