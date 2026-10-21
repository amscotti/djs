const out = process.stdout;
console.log("stdout", out.fd, out.isTTY, typeof out.write);
console.log("stderr", process.stderr.fd, process.stderr.isTTY);
process.stdout.write("written\n");
console.log("stdin", process.stdin.fd, typeof process.stdin.on, process.stdin.isTTY);
