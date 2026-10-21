const cp = require("child_process");

let r = cp.spawnSync("sh", ["-c", "printf out; printf err >&2; exit 3"]);
console.log("sync", r.status, JSON.stringify(r.stdout), JSON.stringify(r.stderr));
r = cp.spawnSync("sh", ["-c", "pwd"], { cwd: "/tmp" });
console.log("cwd", r.stdout.trim());
r = cp.execSync("printf exec");
console.log("exec", JSON.stringify(r.toString()));

// shell:true builds /bin/sh -c "exec <file> <args>"; args are not quoted.
r = cp.spawnSync("printf", ["%s", "shell"], { shell: true });
console.log("shell", r.status, JSON.stringify(r.stdout));

// A large stdin write must not deadlock against a child that echoes it.
r = cp.spawnSync("cat", [], { input: "x".repeat(262144) });
console.log("input", r.status, r.stdout.length);

// Small stdout followed by large stderr must be drained together.
r = cp.spawnSync("sh", ["-c", "echo A; head -c 200000 /dev/zero >&2; echo B"]);
console.log("interleaved", r.status, r.stdout.length, r.stderr.length);

const child = cp.spawn("sh", ["-c", "echo one; echo two >&2"]);
let out = "", err = "";
child.stdout.on("data", c => { out += c; });
child.stderr.on("data", c => { err += c; });
child.on("close", (code, sig) => {
    console.log("spawn", code, sig, JSON.stringify(out), JSON.stringify(err));

    // After close the handle's id is cleared and the table slot may be reused.
    const a = cp.spawn("true", []);
    a.on("close", () => {
        const b = cp.spawn("sleep", ["0.05"]);
        console.log("stale", a.stdin.write("x"), a.kill());
        b.on("close", () => {
            const k = cp.spawn("sleep", ["5"]);
            k.on("close", (code2, sig2) => console.log("killed", code2, sig2));
            k.kill("SIGKILL");
        });
    });
});
