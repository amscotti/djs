const t = setTimeout(() => console.log("bad"), 1000);
t.unref();
console.log("done");
