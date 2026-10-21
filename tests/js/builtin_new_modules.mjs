import path from "node:path";
import { join } from "path";
import os from "os";
import { platform } from "node:os";
console.log(join("/a", "b"), path.basename("/a/b.txt"), path === globalThis.path);
console.log(platform(), os.arch(), os === globalThis.os);
