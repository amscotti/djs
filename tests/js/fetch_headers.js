const h = new Headers({ "X-A": "1" });
h.set("x-b", "2");
h.append("x-a", "3");
const r = new Response("hello", { status: 201, headers: h });
console.log("headers", h.get("x-a"), h.get("x-b"), h.has("X-B"), Array.from(h.keys()).join(","));
console.log("resp", r.status, r.headers.get("x-a"), r.headers.get("x-b"));

(async function () {
    const req = new Request("http://x/a?b=1", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"a":1}'
    });
    const copy = req.clone();
    const value = await req.json();
    console.log("req", req.method, req.url, value.a, req.headers.get("content-type"));
    console.log("clone", await copy.text());
    console.log("used", req.bodyUsed, copy.bodyUsed);
})().catch(function (e) { console.log("ERR", e.message); process.exitCode = 1; });
