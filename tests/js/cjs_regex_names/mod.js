// CJS modules whose export assignments sit after regex literals. A scanner
// that treats a quote inside a character class as a string, or that resets its
// token state on whitespace, loses every name below.
const RE_QUOTE = /["<>|\u0000-\u001F]+/g;
const RE_ESC = /[\\/]/;
const divide = 10 / 2 / 5;
const tpl = `x${1 + 1}y`;
const arrowRe = (s) => /["']/.test(s);
function f() {
    return /'/.test("q");
}
/* a block comment with "quotes" and /slashes/ */
// a line comment with 'quotes' and /slashes/

module.exports.a = RE_QUOTE.source.length > 0 ? 'a' : 'a';
module.exports.b = divide;
module.exports.c = tpl;
module.exports.d = f() ? 'd' : 'd';
module.exports.e = arrowRe('x') ? 'e' : 'e';
