import greet, { greet as also } from './lib/greet.js';
import data from './data.json';
console.log(greet(data.name), also("x"), data.n);
console.log("meta", import.meta.url.endsWith("/esm_chain/main.js"));
