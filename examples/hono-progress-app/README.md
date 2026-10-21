# Hono + HTMX + Alpine progress demo

The same UI and routes as `examples/progress-app`, implemented with Hono and
served on djs.

```bash
npm install
../../djs -A server.js      # http://127.0.0.1:3002
```

## Why there is a small adapter

`@hono/node-server` expects Node's `IncomingMessage` stream conversions
(`Readable.toWeb`) and Node's request lifecycle. djs exposes `http.createServer`
with Node-shaped `req`/`res`, so `server.js` buffers the body and calls
`app.fetch(new Request(url, { method, headers, body }))` directly. Hono's
`fetch` returns a `Response` synchronously; the adapter wraps it with
`Promise.resolve` and copies status, headers and body onto `res`.

That adapter is also what surfaced two runtime gaps fixed in v0.13.2: `Request`
was missing as a global, and `Headers` lacked `set`/`append`/`delete`.
