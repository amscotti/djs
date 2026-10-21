const { URL, URLSearchParams, parse, format } = require("url");
const util = require("util");
const u = new URL("https://user:p@example.com:8080/a/b?x=1&y=two#h");
u.searchParams.append("z", "3");
console.log(u.protocol, u.hostname, u.port, u.pathname, u.searchParams.get("y"), u.searchParams.toString());
console.log(u.href, u.origin);
const p = parse("http://example.com/a?q=1", true);
console.log(p.hostname, p.pathname, p.query.get("q"), format({ protocol: "http:", slashes: true, host: "example.com", pathname: "/b" }));
console.log(util.format("%s:%d", "n", 4), util.inspect({ a: 1 }));
function add(a, b, cb) { cb(null, a + b); }
util.promisify(add)(2, 3).then(v => console.log("promisify", v));
function Base() {} Base.prototype.kind = function () { return "base"; };
function Child() {} util.inherits(Child, Base);
console.log("inherits", new Child().kind());
