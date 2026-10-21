console.log("platform-ok", process.platform === "linux");
console.log("cwd-abs", process.cwd().startsWith("/"));
console.log("argv-file", process.argv.indexOf("tests/js/process_info.js") >= 0);
console.log("env", typeof process.env.PATH === "string");
console.log("version", process.version);
