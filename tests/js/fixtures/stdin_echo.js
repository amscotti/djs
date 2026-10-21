let s = "";
process.stdin.on("data", d => { s += d; });
process.stdin.on("end", () => { process.stdout.write(s); });
