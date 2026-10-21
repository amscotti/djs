import { EventEmitter } from "events";
import { Readable } from "stream";
import { URL } from "url";
import { format } from "util";
const e = new EventEmitter();
e.on("x", v => console.log("esm", v, new URL("https://a/b").hostname, format("%s", "u")));
e.emit("x", 7);
const r = Readable.from(["z"]);
r.on("data", c => console.log("read", c));
