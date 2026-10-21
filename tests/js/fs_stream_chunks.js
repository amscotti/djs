const fs = require("fs");
const path = "/tmp/djs-stream-chunks.bin";
fs.writeFileSync(path, Buffer.alloc(200000, 65));

let chunks = 0, max = 0, total = 0;
const rs = fs.createReadStream(path);
rs.on("data", function (c) {
    chunks += 1;
    if (c.length > max) max = c.length;
    total += c.length;
});
rs.on("end", function () {
    console.log("chunks", chunks > 1, max <= 65536, total === 200000);
    fs.unlinkSync(path);
});
