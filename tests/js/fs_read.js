const path = "tests/js/fixtures/hello.txt";
console.log("sync:" + fs.readFileSync(path, "utf8").trim());
console.log("bytes:" + (fs.readFileSync(path) instanceof Uint8Array));
fs.readFile(path, "utf8", (err, data) => {
    if (err) {
        console.log("cb-error", err.code);
        return;
    }
    console.log("cb:" + data.trim());
    fs.promises.readFile(path, "utf8").then((text) => console.log("promise:" + text.trim()));
});
