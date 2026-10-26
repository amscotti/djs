const fs = require("fs");

const name = process.argv[2];
fs.mkdirSync(name);
const seen = [];
const watcher = fs.watch("./" + name, { recursive: true }, function (event, filename) {
    if (filename === "a.txt") seen.push(filename);
});
setTimeout(function () {
    fs.writeFileSync("./" + name + "/a.txt", "x");
}, 500);
setTimeout(function () {
    watcher.close();
    console.log("relative-name", seen.length > 0, seen.length > 0 ? seen[0] : "-");
    fs.rmSync(name, { recursive: true, force: true });
}, 1600);
