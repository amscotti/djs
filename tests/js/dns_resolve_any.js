// dns.resolveAny: an ANY (qtype 255) query whose answer mixes record types.
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
function questionEnd(q) { let off = 12; while (q[off]) off += 1 + q[off]; return off + 1; }
function qname(q) {
    let off = 12; const labels = [];
    while (q[off]) { const len = q[off]; labels.push(q.slice(off + 1, off + 1 + len).toString()); off += 1 + len; }
    return labels.join(".");
}
function rr(type, rdata, ttl) {
    const head = Buffer.alloc(10);
    head.writeUInt16BE(0xC00C, 0);
    head.writeUInt16BE(type, 2);
    head.writeUInt16BE(1, 4);
    head.writeUInt32BE(ttl === undefined ? 60 : ttl, 6);
    const tail = Buffer.alloc(2);
    tail.writeUInt16BE(rdata.length, 0);
    return Buffer.concat([head, tail, rdata]);
}
function u16(n) { const b = Buffer.alloc(2); b.writeUInt16BE(n, 0); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32BE(n, 0); return b; }
function txt(s) { const b = Buffer.from(s); return Buffer.concat([Buffer.from([b.length]), b]); }
function caaRdata(flags, tag, value) {
    return Buffer.concat([Buffer.from([flags, Buffer.byteLength(tag)]), Buffer.from(tag), Buffer.from(value)]);
}
function naptrRdata(order, pref, flags, service, regexp, replacement) {
    const str = function (s) { const b = Buffer.from(s); return Buffer.concat([Buffer.from([b.length]), b]); };
    return Buffer.concat([u16(order), u16(pref), str(flags), str(service), str(regexp), encodeName(replacement)]);
}

const A = function () { return rr(1, Buffer.from([192, 0, 2, 10])); };
const AAAA = function () { return rr(28, Buffer.from([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])); };
const MX = function () { return rr(15, Buffer.concat([u16(10), encodeName("mail.example.test")])); };
const TXT = function () { return rr(16, txt("v=spf1 -all")); };
const NS = function () { return rr(2, encodeName("ns1.example.test")); };
const PTR = function () { return rr(12, encodeName("ptr.example.test")); };
const CNAME = function () { return rr(5, encodeName("alias.example.test")); };
const SRV = function () { return rr(33, Buffer.concat([u16(5), u16(10), u16(443), encodeName("svc.example.test")])); };
const SOA = function () {
    return rr(6, Buffer.concat([encodeName("ns1.example.test"), encodeName("hostmaster.example.test"),
        u32(7), u32(3600), u32(600), u32(86400), u32(300)]));
};
const CAA = function () { return rr(257, caaRdata(0, "issue", "ca.example.test")); };
const NAPTR = function () { return rr(35, naptrRdata(100, 10, "s", "SIP+D2U", "!", "_sip._udp.example.test")); };

const answers = {
    "mixed.example.test": [A(), MX(), TXT()],
    "addr.example.test": [A(), AAAA()],
    "soa.example.test": [SOA()],
    "srv.example.test": [SRV()],
    "ptr.example.test": [PTR()],
    "ns.example.test": [NS()],
    "cname.example.test": [CNAME()],
    "caa.example.test": [CAA()],
    "naptr.example.test": [NAPTR()],
    "empty.example.test": []
};

const server = dgram.createSocket("udp4");
server.on("message", function (msg, rinfo) {
    const qe = questionEnd(msg);
    const name = qname(msg);
    const qtype = msg.readUInt16BE(qe);
    let records = answers[name] || [];
    let rcode = 0;
    if (name.indexOf("missing") === 0) rcode = 3;
    else if (qtype !== 255) { records = []; rcode = 3; }

    const head = Buffer.from(msg.slice(0, qe + 4));
    head.writeUInt16BE(0x8180 | rcode, 2);
    head.writeUInt16BE(records.length, 6);
    head.writeUInt16BE(0, 8);
    head.writeUInt16BE(0, 10);
    server.send(Buffer.concat([head].concat(records)), rinfo.port, rinfo.address);
});

server.bind(0, "127.0.0.1", function () {
    dns.setServers(["127.0.0.1:" + server.address().port]);
    const cases = ["mixed", "addr", "soa", "srv", "ptr", "ns", "cname", "caa", "naptr", "empty", "missing"];
    let index = 0;
    function next() {
        if (index >= cases.length) {
            dns.promises.resolveAny("mixed.example.test").then(function (list) {
                console.log("promise", list.length, list[0].type);
                server.close();
            });
            return;
        }
        const label = cases[index++];
        dns.resolveAny(label + ".example.test", function (err, list) {
            console.log(label, err ? "err=" + err.code : JSON.stringify(list));
            next();
        });
    }
    next();
});
