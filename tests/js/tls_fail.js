const tls = require("tls");

// Failed handshakes must release the worker job, socket and table slot.
let done = 0;
const N = 20;
for (let i = 0; i < N; i++) {
    const s = tls.connect({ host: "127.0.0.1", port: 1, rejectUnauthorized: false });
    s.on("error", () => {
        done++;
        if (done === N) console.log("connect-failed", done);
    });
}
