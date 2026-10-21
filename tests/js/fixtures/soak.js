const start = process.memoryUsage();
for (let i = 0; i < 200000; i++) {
    const t = setTimeout(() => {}, 1000);
    clearTimeout(t);
}
let reads = 0;
const total = 3000;
function next() {
    if (reads >= total) {
        const end = process.memoryUsage();
        console.log("reads", reads);
        console.log("heap_delta", Math.round((end.heapUsed - start.heapUsed) / 1024));
        console.log("arraybuffers", end.arrayBuffers >= 0);
        return;
    }
    fs.promises.readFile("tests/js/fixtures/hello.txt", "utf8").then(() => {
        reads++;
        next();
    }, (e) => { console.log("read-error", e.code); process.exit(1); });
}
next();
