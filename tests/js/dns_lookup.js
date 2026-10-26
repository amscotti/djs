// dns.lookup options: family, all, hints and order/verbatim. Promises are
// sequential so the golden is deterministic; numbers are used where possible
// so host resolver configuration cannot change the result.
const dns = require("dns");

(async function () {
    const a = await dns.promises.lookup("127.0.0.1", { all: true });
    console.log("all-v4", a.length === 1 && a[0].address === "127.0.0.1" && a[0].family === 4);

    const b = await dns.promises.lookup("::1", { family: 6, all: true });
    console.log("all-v6", b.length === 1 && b[0].address === "::1" && b[0].family === 6);

    const c = await dns.promises.lookup("localhost", { all: true });
    console.log("all-shape", Array.isArray(c) && c.length >= 1 &&
        c.every(function (x) { return typeof x.address === "string" && (x.family === 4 || x.family === 6); }));

    const d = await dns.promises.lookup("localhost", { family: 4 });
    console.log("family-4", d.family === 4 && d.address.indexOf("127.") === 0);

    const e = await dns.promises.lookup("localhost", { all: true, order: "ipv4first" });
    console.log("order-4", e.length > 0 && e[0].family === 4);

    const f = await dns.promises.lookup("localhost", { all: true, verbatim: false });
    console.log("verbatim-false", f.length > 0 && f[0].family === 4);

    try {
        dns.lookup("localhost", { family: 5 }, function () {});
        console.log("bad-family none");
    } catch (e) {
        console.log("bad-family", e.name, e.code);
    }
})().catch(function (e) {
    console.log("error", e.code || e.message);
    process.exitCode = 1;
});
