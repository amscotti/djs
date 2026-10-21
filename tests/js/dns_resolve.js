const dns = require("dns");

dns.resolve4("localhost", function (err, list) {
    console.log("resolve4", err ? err.code : list.join(","));
    dns.resolve6("localhost", function (e2, l2) {
        console.log("resolve6", e2 ? e2.code : l2.join(","));
        dns.resolve("localhost", "AAAA", function (e3, l3) {
            console.log("resolve-aaaa", e3 ? e3.code : (Array.isArray(l3) ? "array" : "bad"));
        });
    });
});
