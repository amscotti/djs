const path = "tests/tmp/write_test.txt";
fs.writeFileSync(path, "one\n");
console.log("sync:" + fs.readFileSync(path, "utf8").trim());
fs.writeFile(path, "two\n", (err) => {
    if (err) {
        console.log("async-error", err.code);
        return;
    }
    console.log("async:" + fs.readFileSync(path, "utf8").trim());
});
