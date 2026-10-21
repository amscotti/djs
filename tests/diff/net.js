const net = require("net");
const dns = require("dns");
const s = net.connect(1, "127.0.0.1");
s.on("error", e => {
    console.log("connect", e.code);
    dns.lookup("no-such-host.invalid", err => {
        console.log("dns", err && err.code);
    });
});
