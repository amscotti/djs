const cp = require("child_process");
const child = cp.spawn(process.execPath,
    ["--allow-env", "-e", "console.log('child-env', process.env.FOO, process.env.PATH)"],
    { env: { FOO: "bar", PATH: "/usr/bin:/bin" } });
child.stdout.on("data", function (d) { process.stdout.write(d); });
child.on("close", function (code) { console.log("child-exit", code); });
