const pkg = require('esc-pkg');
console.log('loaded', pkg.tag);
console.log('name', pkg.name);
// require.resolve exercises the same escaped package.json path.
console.log('resolve', require.resolve('esc-pkg').endsWith('lib/x.js'));
// A JSON import goes through the engine parser, not the package reader;
// this one keeps a surrogate pair intact end to end.
import('./data.json').then(function (m) {
    console.log('json-import', m.default.pair === 'a\u{1F600}b');
    console.log('done');
});
