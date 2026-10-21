import data from './data.json';
import attrs from './attrs.json' with { type: "json" };
console.log(data.name, data.n, Array.isArray(data.list));
console.log("attrs", attrs.ok);
