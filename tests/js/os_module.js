console.log(os.platform(), os.arch(), os.type());
console.log(typeof os.release(), typeof os.hostname(), os.eol === "\n");
console.log(os.tmpdir().length > 0, os.homedir().length >= 0, os.devNull);
console.log(Array.isArray(os.cpus()), os.cpus().length > 0);
console.log(os.totalmem() > 0, os.freemem() >= 0);
console.log(typeof os.endianness, os.endianness());
