import fs, { readFileSync, writeFileSync } from 'node:fs';
import proc, { platform } from 'node:process';
import { readFile } from 'fs/promises';
console.log("builtin", typeof readFileSync, typeof writeFileSync, typeof readFile);
console.log("platform", platform, proc.version);
