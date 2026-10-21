// Async and promise surfaces that used to hang or throw: stream async
// iteration, finished(), events.on(), process lifecycle events and rejection
// handling. Every line is deterministic; a regression shows up as a hang
// (the suite times out) or a diff against the golden.
const { spawn } = require('node:child_process');
const { Readable, PassThrough } = require('node:stream');
const { finished } = require('node:stream/promises');
const { EventEmitter, once, setMaxListeners, on } = require('node:events');

async function collect(stream) {
    let bytes = 0;
    for await (const chunk of stream) bytes += chunk.length;
    return bytes;
}

(async () => {
    // 1. for-await over child stdout (data and EOF arrive in the same turn).
    const child = spawn('echo', ['hello']);
    console.log('child iterate', await collect(child.stdout));

    // 2. for-await over chunks pushed back-to-back, before the first next().
    const mem = new Readable();
    mem.push('a');
    mem.push('bc');
    mem.push('def');
    mem.push(null);
    console.log('memory iterate', await collect(mem));

    // 3. A stream error must reject the loop, not throw from an event handler.
    const broken = new Readable();
    const errored = (async () => {
        try {
            for await (const chunk of broken) void chunk;
            return 'resolved';
        } catch (error) {
            return 'rejected ' + error.message;
        }
    })();
    broken.emit('error', new Error('stream-broke'));
    console.log('error', await errored);

    // 4. finished() on an unconsumed child stdout, and on an already-ended one.
    const quiet = spawn('echo', ['quiet']);
    await finished(quiet.stdout);
    console.log('finished child resolved');
    const ended = new PassThrough();
    ended.end('x');
    await new Promise((resolve) => setTimeout(resolve, 5));
    await finished(ended);
    console.log('finished ended resolved');

    // 5. events.on() is an async iterator that yields every event.
    const emitter = new EventEmitter();
    const seen = [];
    const iterating = (async () => {
        for await (const [value] of on(emitter, 'tick')) {
            seen.push(value);
            if (seen.length === 2) break;
        }
    })();
    emitter.emit('tick', 'one');
    emitter.emit('tick', 'two');
    await iterating;
    console.log('events.on', seen.length, seen.join(','));

    // 6. events.once() still resolves with the arguments array.
    const e2 = new EventEmitter();
    const p = once(e2, 'go');
    e2.emit('go', 7);
    console.log('once', (await p).join(','));

    // 7. setMaxListeners accepts Infinity and per-target emitters.
    setMaxListeners(Infinity, e2);
    console.log('maxListeners ok', e2.getMaxListeners() === Infinity);

    // 8. stdio is exposed, as packages expect from a spawned child.
    const s = spawn('true', []);
    console.log('stdio', s.stdio.length, s.stdio[2] === s.stderr);

    // 9. A registered unhandledRejection listener takes the rejection without
    //    aborting the process.
    process.on('unhandledRejection', (reason) => console.log('handled', reason.message));
    Promise.reject(new Error('boom'));

    // 10. listenerCount and the lifecycle events, printed last.
    console.log('listeners', process.listenerCount('unhandledRejection'));
    process.on('beforeExit', (code) => console.log('beforeExit', code));
    process.on('exit', (code) => console.log('exit', code));
})();
