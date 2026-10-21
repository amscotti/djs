# DeepSeek chat via the OpenAI SDK

Calls DeepSeek with the official `openai` package running on djs: one buffered
completion and one streamed completion.

```bash
npm install
export DEEPSEEK_API_KEY=...        # from ~/.hermes/.env or your own account
../../djs -A chat.js
```

Environment:

- `DEEPSEEK_API_KEY` (required) — never printed by the script
- `DEEPSEEK_BASE_URL` (default `https://api.deepseek.com`)
- `DEEPSEEK_MODEL` (default `deepseek-chat`)

The script prints model, token usage, latency and the reply, then streams a
second answer and reports the chunk count.

This example found four runtime gaps fixed in v0.13.3: missing `FormData`,
non-iterable `Headers`, `ClientRequest` copying `Headers` prototype methods as
header values, and `Response.body` being absent. Note that the HTTP client still
buffers the whole response before exposing it, so the stream arrives as one
chunk and the SDK's SSE parser splits it into events — correct output, no
per-token latency.
