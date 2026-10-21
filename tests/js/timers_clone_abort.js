const timers = require("timers/promises");
(async () => {
    const v = await timers.setTimeout(1, "tick");
    const i = await timers.setImmediate("now");
    console.log("timers", v, i);
    const src = { a: [1, { b: 2 }], d: new Date(0) };
    src.self = src;
    const copy = structuredClone(src);
    console.log("clone", copy.a[1].b, copy.d.getTime(), copy.self === copy, copy !== src);
    const c = new AbortController();
    c.signal.on("abort", () => console.log("abort", c.signal.aborted, c.signal.reason.message));
    c.abort(new Error("stop"));
    try { c.signal.throwIfAborted(); } catch (e) { console.log("throw", e.message); }
})();
