const before = process.memoryUsage().arrayBuffers;
const keep = [];
for (let i = 0; i < 4; i++) keep.push(new ArrayBuffer(1024 * 1024));
const after = process.memoryUsage().arrayBuffers;
console.log("grew", after - before >= 4 * 1024 * 1024, keep.length);
console.log("types", typeof before, typeof process.memoryUsage().external);
