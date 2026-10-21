const rl = require("readline").createInterface({ input: process.stdin });
const lines = [];
rl.on("line", l => lines.push(l));
rl.on("close", () => console.log(lines.join("|")));
