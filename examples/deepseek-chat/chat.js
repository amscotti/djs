// Minimal DeepSeek chat client using the official OpenAI SDK on djs.
// The key is read from the environment; it is never printed.
const OpenAI = require("openai");

const client = new OpenAI({
    apiKey: process.env.DEEPSEEK_API_KEY,
    baseURL: process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com"
});

const MODEL = process.env.DEEPSEEK_MODEL || "deepseek-chat";

async function main() {
    const started = Date.now();
    const completion = await client.chat.completions.create({
        model: MODEL,
        messages: [
            { role: "system", content: "You are terse. One sentence, no preamble." },
            { role: "user", content: "What is QuickJS in one sentence?" }
        ],
        max_tokens: 80
    });

    console.log("status", "ok");
    console.log("model", completion.model);
    console.log("usage", completion.usage.prompt_tokens, completion.usage.completion_tokens);
    console.log("reply", completion.choices[0].message.content.trim());
    console.log("latency_ms", Date.now() - started);

    const stream = await client.chat.completions.create({
        model: MODEL,
        messages: [
            { role: "user", content: "Count from 1 to 5, comma separated, nothing else." }
        ],
        max_tokens: 40,
        stream: true
    });

    const streamStart = Date.now();
    let text = "";
    let chunks = 0;
    let firstTokenMs = 0;
    for await (const part of stream) {
        chunks++;
        const delta = part.choices[0] && part.choices[0].delta && part.choices[0].delta.content;
        if (delta) {
            if (!firstTokenMs) firstTokenMs = Date.now() - streamStart;
            text += delta;
        }
    }
    console.log("stream", JSON.stringify(text.trim()));
    console.log("chunks", chunks, "first_token_ms", firstTokenMs, "stream_total_ms", Date.now() - streamStart);
}

main().catch(function (e) {
    console.log("error", e.status || "", e.message);
    if (process.env.DEBUG_STACK) console.log(e.stack);
    if (e.cause) console.log("cause", e.cause.message, e.cause.code || "", e.cause.stack ? e.cause.stack.split("\n").slice(0,3).join(" | ") : "");
    process.exitCode = 1;
});
