const m = await import("./fixtures/dynamic_dep.mjs");
console.log("dynamic", m.value);
