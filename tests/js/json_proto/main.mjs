import data from "./data.json" with { type: "json" };
console.log(Object.keys(data).join(","), data.polluted, ({}).polluted);
console.log(Object.prototype.hasOwnProperty.call(data, "__proto__"),
             Object.getPrototypeOf(data) === Object.prototype);
