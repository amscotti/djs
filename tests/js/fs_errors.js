try {
    fs.readFileSync("tests/js/fixtures/missing.txt");
} catch (e) {
    console.log("sync", e.code, e.syscall);
}
fs.readFile("tests/js/fixtures/missing.txt", (e) => {
    console.log("async", e && e.code);
});
