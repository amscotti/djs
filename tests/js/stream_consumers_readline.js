const { PassThrough } = require("stream");
const consumers = require("stream/consumers");
const readline = require("readline/promises");

async function main() {
    const textStream = new PassThrough();
    setTimeout(function () { textStream.end("hello"); }, 0);
    console.log("text", await consumers.text(textStream));

    const jsonStream = new PassThrough();
    setTimeout(function () { jsonStream.end('{"a":1}'); }, 0);
    console.log("json", (await consumers.json(jsonStream)).a);

    const bufferStream = new PassThrough();
    setTimeout(function () { bufferStream.end("abc"); }, 0);
    console.log("buffer", (await consumers.buffer(bufferStream)).length);

    const input = new PassThrough();
    const rl = readline.createInterface({ input: input, terminal: false });
    const pending = rl.question("? ");
    input.write("answer\n");
    console.log("readline", await pending);
    rl.close();
}
main();
