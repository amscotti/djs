const os = require("os");
console.log(os.platform(), os.arch());
console.log(os.cpus().length > 0, os.totalmem() > 0, os.tmpdir().length > 0);
console.log(typeof os.endianness, os.endianness());
