// Response-splitting regression: header names, values, status messages and
// the status code on the server response path are validated exactly like
// the client path. CRLF must never reach the wire; a bad status code must
// throw ERR_HTTP_INVALID_STATUS_CODE.
const http = require('http');

function fresh() {
    return new http.ServerResponse({ write: function () {} }, { method: 'GET' }, null);
}

let step = 0;
function next(label, fn) {
    step += 1;
    try {
        fn();
        console.log(label, 'no-throw');
    } catch (e) {
        console.log(label, e.code || e.name);
    }
    if (step === 6) console.log('done');
}

next('setheader-crlf', function () {
    fresh().setHeader('Location', '/ok\r\nX-Injected: 1');
});
next('setheader-crlf-name', function () {
    fresh().setHeader('X-Bad\r\n', 'v');
});
next('appendheader-crlf', function () {
    const r = fresh();
    r.setHeader('a', '1');
    r.appendHeader('a', '2\r\nX-Injected: 1');
});
next('writehead-status', function () {
    fresh().writeHead(9999);
});
next('writehead-message', function () {
    fresh().writeHead(200, 'fine\r\nX-Injected: 1');
});
next('writeearlyhints-crlf', function () {
    fresh().writeEarlyHints({ Link: '</a>\r\nX-Injected: 1' });
});
