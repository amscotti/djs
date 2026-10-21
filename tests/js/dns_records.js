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
function qname(q) {
    let off = 12, labels = [];
    while (q[off]) { const len = q[off]; labels.push(q.slice(off + 1, off + 1 + len).toString()); off += 1 + len; }
    return labels.join(".");
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
function u16(n) { const b = Buffer.alloc(2); b.writeUInt16BE(n, 0); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32BE(n, 0); return b; }
function txt(str) { const b = Buffer.from(str); return Buffer.concat([Buffer.from([b.length]), b]); }

const server = dgram.createSocket("udp4");
server.on("message", function (msg, rinfo) {
    const qe = questionEnd(msg);
    const qtype = msg.readUInt16BE(qe);
    let rdata, rcode = 0;
    if (qname(msg).indexOf("missing") === 0) rcode = 3;
    else if (qtype === 15) rdata = Buffer.concat([u16(10), encodeName("mail.example.test")]);
    else if (qtype === 16) rdata = txt("v=spf1 -all");
    else if (qtype === 33) rdata = Buffer.concat([u16(5), u16(10), u16(443), encodeName("svc.example.test")]);
    else if (qtype === 5) rdata = encodeName("alias.example.test");
    else if (qtype === 2) rdata = encodeName("ns1.example.test");
    else if (qtype === 12) rdata = encodeName("ptr.example.test");
    else if (qtype === 6) rdata = Buffer.concat([encodeName("ns1.example.test"), encodeName("hostmaster.example.test"), u32(7), u32(3600), u32(600), u32(86400), u32(300)]);
    else if (qtype === 1) rdata = Buffer.from([192, 0, 2, 10]);
    else if (qtype === 28) rdata = Buffer.from([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    else rcode = 3;

    const head = Buffer.from(msg.slice(0, qe + 4));
    head.writeUInt16BE(0x8180 | rcode, 2);
    head.writeUInt16BE(rcode === 0 ? 1 : 0, 6);
    head.writeUInt16BE(0, 8);
    head.writeUInt16BE(0, 10);
    const reply = rcode === 0 ? Buffer.concat([head, answer(qtype, rdata)]) : head;
    server.send(reply, rinfo.port, rinfo.address);
});

server.bind(0, "127.0.0.1", function () {
    dns.setServers(["127.0.0.1:" + server.address().port]);
    console.log("servers", dns.getServers()[0].indexOf("127.0.0.1:") === 0);

    dns.resolveMx("example.test", function (err, list) {
        console.log("mx", !err, list.length, list[0].priority, list[0].exchange);

        dns.resolveTxt("example.test", function (err2, txts) {
            console.log("txt", !err2, txts.length, txts[0][0]);

            dns.resolveSrv("_svc._tcp.example.test", function (err3, srv) {
                console.log("srv", !err3, srv[0].port, srv[0].name);

                dns.resolveCname("www.example.test", function (err4, cname) {
                    console.log("cname", !err4, cname[0]);

                    dns.resolveNs("example.test", function (err5, ns) {
                        console.log("ns", !err5, ns[0]);

                        dns.resolveSoa("example.test", function (err6, soa) {
                            console.log("soa", !err6, soa.serial, soa.nsname);

                            Promise.all([
                                dns.promises.resolveMx("example.test"),
                                dns.promises.resolve4("example.test"),
                                dns.promises.resolve6("example.test"),
                                dns.promises.resolveSoa("example.test")
                            ]).then(function (results) {
                                console.log("promise-mx", results[0][0].exchange);
                                console.log("promise-a", results[1][0]);
                                console.log("promise-aaaa", results[2][0]);
                                console.log("promise-soa", results[3].serial, results[3].nsname);

                                dns.reverse("192.0.2.10", function (errR, hosts) {
                                    console.log("reverse", !errR, hosts && hosts[0]);

                                    Promise.all([
                                        dns.promises.reverse("192.0.2.10"),
                                        dns.promises.reverse("::1")
                                    ]).then(function (revs) {
                                        console.log("promise-reverse", revs[0][0], revs[1][0]);

                                        dns.resolveMx("missing.example.test", function (err7) {
                                            console.log("nxdomain", err7 && err7.code);
                                            server.close();
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
});
