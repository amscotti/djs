# Express + HTMX + Alpine progress demo

Runs unchanged on djs.

```bash
npm install
../../djs -A server.js      # http://127.0.0.1:3001
```

- `POST /start` begins a five-step job and returns the first fragment.
- `GET /progress` returns the fragment with `hx-get`/`hx-trigger="every 400ms"`.
  When the job finishes the fragment omits those attributes, so HTMX stops
  polling by itself.
- `GET /api/status` is a JSON view for curl/tests.
- Alpine drives the theme toggle and counts `htmx:afterSwap` events.

No build step, no client-side code of our own — everything is HTMX attributes
plus Alpine directives, both vendored under `public/vendor/`.
