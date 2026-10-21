// dns.lookupService: reverse lookup of an IP literal, plus the promise form.
const dns = require("node:dns");

try { dns.lookupService("nope", 0, function () {}); } catch (e) { console.log("bad-address", e.code); }
try { dns.lookupService("127.0.0.1", 70000, function () {}); } catch (e) { console.log("bad-port", e.code); }
try { dns.lookupService(42, 0, function () {}); } catch (e) { console.log("bad-type", e.code); }
try { dns.promises.lookupService("bad", 0); } catch (e) { console.log("promise-bad", e.code); }

// Chained so the output does not depend on which reverse lookup finishes first.
dns.lookupService("127.0.0.1", 0, function (err, hostname, service) {
    console.log("v4", err && err.code, hostname, service);
    dns.lookupService("::1", 0, function (err2, hostname2, service2) {
        console.log("v6", err2 && err2.code, hostname2, service2);
        dns.promises.lookupService("127.0.0.1", 22).then(function (r) {
            console.log("promise", r.hostname, r.service);
        });
    });
});
