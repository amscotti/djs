// dns.resolve4/resolve6/resolve use the configured DNS servers, not the
// platform's /etc/hosts. Keep this test hermetic with a local DNS fixture:
// GitHub's macOS runner returns EBADRESP for a system resolve of localhost.
const dgram = require("dgram");
const dns = require("dns");

function encodeName(name) {
    const parts = [];
    for (const label of name.replace(/\.$/, "").split(".")) {
        const b = Buffer.from(label);
        parts.push(Buffer.from([b.length]), b);
    }
    parts.push(Buffer.from([0]));
    return Buffer.concat(parts);
}

function questionEnd(q) {
    let off = 12;
    while (q[off]) off += 1 + q[off];
    return off + 1;
}

function answer(type, rdata) {
    const head = Buffer.alloc(10);
    head.writeUInt16BE(0xC00C, 0);
    head.writeUInt16BE(type, 2);
    head.writeUInt16BE(1, 4);
    head.writeUInt32BE(60, 6);
    const tail = Buffer.alloc(2);
    tail.writeUInt16BE(rdata.length, 0);
    return Buffer.concat([head, tail, rdata]);
}

const server = dgram.createSocket("udp4");
server.on("message", function (msg, rinfo) {
    const qe = questionEnd(msg);
    const qtype = msg.readUInt16BE(qe);
    let rdata = null;
    if (qtype === 1)
        rdata = Buffer.from([192, 0, 2, 7]);
    else if (qtype === 28)
        rdata = Buffer.from([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]);

    const head = Buffer.from(msg.slice(0, qe + 4));
    head.writeUInt16BE(rdata ? 0x8180 : 0x8183, 2);
    head.writeUInt16BE(rdata ? 1 : 0, 6);
    head.writeUInt16BE(0, 8);
    head.writeUInt16BE(0, 10);
    const reply = rdata ? Buffer.concat([head, answer(qtype, rdata)]) : head;
    server.send(reply, rinfo.port, rinfo.address);
});

server.bind(0, "127.0.0.1", function () {
    dns.setServers(["127.0.0.1:" + server.address().port]);
    dns.resolve4("resolve.example.test", function (err, list) {
        console.log("resolve4", err ? err.code : list.join(","));
        dns.resolve6("resolve.example.test", function (err6, list6) {
            console.log("resolve6", err6 ? err6.code : list6.join(","));
            dns.resolve("resolve.example.test", "AAAA", function (errA, listA) {
                console.log("resolve-aaaa", errA ? errA.code : (Array.isArray(listA) ? "array" : "bad"));
                server.close();
            });
        });
    });
});
