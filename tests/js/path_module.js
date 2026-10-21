console.log(path.join("/a", "b", "..", "c"));
console.log(path.resolve("/a/b", "../c"), path.resolve("/x", "/y"));
console.log(path.dirname("/a/b/c.txt"), path.basename("/a/b/c.txt"), path.basename("/a/b/c.txt", ".txt"));
console.log(path.extname("x.tar.gz"), path.extname(".bashrc"), path.extname("noext"));
console.log(path.relative("/a/b", "/a/c/d"), path.relative("/a/b", "/a/b"));
console.log(path.isAbsolute("/x"), path.isAbsolute("x"), path.normalize("/a//b/./../c"));
console.log(path.sep, path.posix === path);
console.log(path.normalize("a/./b/"), path.join("a/", "/b/"), path.extname("a."), path.normalize("./"));
