const path = require("path");
console.log(path.join("/a", "b", "..", "c"));
console.log(path.dirname("/a/b/c.txt"), path.basename("/a/b/c.txt"), path.basename("/a/b/c.txt", ".txt"));
console.log(path.extname("x.tar.gz"), path.extname(".bashrc"));
console.log(path.relative("/a/b", "/a/c/d"), path.isAbsolute("/x"), path.normalize("/a//b/./../c"));
console.log(path.normalize("a/./b/"), path.join("a/", "/b/"), path.extname("a."), path.normalize("./"));
