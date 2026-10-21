# Express on djs

Express 4 runs unmodified on the runtime. Install once and start it:

```sh
cd examples/express-app
npm install --no-audit --no-fund
../../djs -A app.js
```

Then:

```sh
curl http://127.0.0.1:3100/                 # static index.html
curl http://127.0.0.1:3100/api/items         # JSON
curl http://127.0.0.1:3100/api/user/42       # route params
curl -X POST -H 'content-type: application/json' \
     -d '{"x":1}' http://127.0.0.1:3100/api/echo
```

`scripts/gate-express.sh` runs the same checks; it skips when Express is not
installed and the registry is unreachable, so the default gate stays offline.

What Express exercised, and what had to be fixed for it: `Error.captureStackTrace`
with `Error.prepareStackTrace` returning V8-style CallSite objects, callable
`require('stream')`, `EventEmitter` methods usable on objects that never ran the
constructor, `__dirname`/`__filename` for the main module, `fs.ReadStream`/
`fs.WriteStream` constructors, `Buffer.allocUnsafeSlow`/`compare`,
`querystring`, `string_decoder` and `tty`.
