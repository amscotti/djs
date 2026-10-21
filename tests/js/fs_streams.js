const fs = require("fs");
let data = "";
const r = fs.createReadStream("tests/js/fixtures/hello.txt");
r.on("data", c => { data += c; });
r.on("end", () => {
    const w = fs.createWriteStream("/tmp/djs-fs-stream.txt");
    w.write("one");
    w.end("two");
    w.on("finish", () => console.log(data.trim(), fs.readFileSync("/tmp/djs-fs-stream.txt", "utf8")));
});
