const { ReadableStream, WritableStream, TransformStream } = require("stream/web");

async function collect(stream) {
    const reader = stream.getReader();
    const out = [];
    for (;;) {
        const r = await reader.read();
        if (r.done) return out;
        out.push(r.value);
    }
}

(async function () {
    const basic = new ReadableStream({
        start(c) { c.enqueue(1); c.enqueue(2); c.close(); }
    });
    console.log("readable", (await collect(basic)).join(","));

    const source = new ReadableStream({
        start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); }
    });
    const chunks = [];
    await source.pipeTo(new WritableStream({ write(chunk) { chunks.push(chunk); } }));
    console.log("pipe", chunks.join("|"));

    const upper = new TransformStream({ transform(chunk) { return String(chunk).toUpperCase(); } });
    const transformed = collect(upper.readable);
    const writer = upper.writable.getWriter();
    await writer.write("hi");
    await writer.write("there");
    await writer.close();
    console.log("transform", (await transformed).join("-"));

    const pulled = [];
    const generated = new ReadableStream({
        pull(c) {
            pulled.push(pulled.length);
            c.enqueue(pulled.length);
            if (pulled.length === 3) c.close();
        }
    });
    console.log("pull", (await collect(generated)).join(","));
})().catch(function (e) { console.log("ERR", e.message); process.exitCode = 1; });
