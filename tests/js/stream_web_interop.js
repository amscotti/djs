const { Readable, Writable, Duplex, addAbortSignal } = require("stream");

(async function () {
    const webReadable = Readable.toWeb(Readable.from(["a", "b", "c"]));
    const reader = webReadable.getReader();
    let text = "";
    for (;;) {
        const r = await reader.read();
        if (r.done) break;
        text += Buffer.from(r.value).toString();
    }
    console.log("toWeb", text);

    const web = new ReadableStream({
        start(c) {
            c.enqueue(Buffer.from("x"));
            c.enqueue(Buffer.from("y"));
            c.close();
        }
    });
    let back = "";
    for await (const chunk of Readable.fromWeb(web)) back += chunk.toString();
    console.log("fromWeb", back);

    const objectWeb = new ReadableStream({
        start(c) { c.enqueue({ n: 1 }); c.enqueue({ n: 2 }); c.close(); }
    });
    const objects = [];
    for await (const value of Readable.fromWeb(objectWeb, { objectMode: true })) objects.push(value.n);
    console.log("objectMode", objects.join(","));

    let sink = "";
    const webWritable = Writable.toWeb(new Writable({
        write(chunk, enc, cb) { sink += chunk.toString(); cb(); }
    }));
    const writer = webWritable.getWriter();
    await writer.write(Buffer.from("he"));
    await writer.write(Buffer.from("llo"));
    await writer.close();
    console.log("toWebWritable", sink);

    let collected = "";
    const customSink = new WritableStream({
        write(chunk) { collected += Buffer.from(chunk).toString(); }
    });
    const nodeWritable = Writable.fromWeb(customSink);
    await new Promise((resolve, reject) => {
        nodeWritable.write("ab", err => err ? reject(err) : resolve());
    });
    await new Promise((resolve, reject) => nodeWritable.end("cd", err => err ? reject(err) : resolve()));
    console.log("fromWebWritable", collected);

    const controller = new AbortController();
    const aborted = addAbortSignal(controller.signal, new Readable());
    aborted.on("error", e => console.log("abort", e.name, e.code));
    controller.abort();

    const pair = Duplex.toWeb(new Duplex());
    console.log("duplex", typeof pair.readable.getReader, typeof pair.writable.getWriter);
})().catch(function (e) { console.log("ERR", e.message); process.exitCode = 1; });
