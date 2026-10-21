const t = setTimeout(() => console.log("refreshed"), 50);
console.log("ref", t.hasRef());
t.unref();
console.log("unref", t.hasRef());
t.ref();
console.log("ref2", t.hasRef());
t.refresh();
