// fs.watch event coverage beyond the single create case in fs_watch.js.
// Each mutation runs in its own phase so create/write/rename/delete are
// asserted independently; FSEvents may report a write as "rename", so the
// write assertion accepts any event carrying the filename.
const fs = require('fs');
const path = require('path');
const os = require('os');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'djs-watch-'));
const base = path.basename(dir);
try {
    fs.watch(path.join(dir, 'missing'), function () {});
    console.log('missing-error none');
} catch (e) {
    console.log('missing-error', e.code);
}
let phase = 0;
const seen = [];
const watcher = fs.watch(dir, function (event, filename) {
    seen.push([event, filename, phase]);
});
const fileSeen = [];
const file = path.join(dir, 'single.txt');
fs.writeFileSync(file, 'x');
const fileWatcher = fs.watch(file, function (event, filename) {
    fileSeen.push([event, filename]);
});

function at(name, firstPhase, lastPhase) {
    return seen.filter(function (e) {
        return e[1] === name && e[2] >= firstPhase && e[2] <= lastPhase;
    });
}

function proceed() {
    phase = 1;
    fs.writeFileSync(path.join(dir, 'a.txt'), 'one');          // create
    setTimeout(function () {
        phase = 2;
        fs.writeFileSync(path.join(dir, 'a.txt'), 'two');      // write
        setTimeout(function () {
            phase = 3;
            fs.renameSync(path.join(dir, 'a.txt'), path.join(dir, 'b.txt'));
            setTimeout(function () {
                phase = 4;
                fs.writeFileSync(path.join(dir, 'gone.txt'), 'x'); // create
                setTimeout(function () {
                    phase = 5;
                    fs.unlinkSync(path.join(dir, 'gone.txt'));     // delete
                    setTimeout(function () {
                        fs.appendFileSync(file, 'y');              // file watch
                        setTimeout(finish, 900);
                    }, 900);
                }, 900);
            }, 900);
        }, 900);
    }, 900);
}

function finish() {
    const dirEvents = seen.filter(function (e) { return e[1] !== base; });
    const create = at('a.txt', 1, 1);
    const wrote = at('a.txt', 2, 2);
    const renamed = seen.filter(function (e) {
        return (e[1] === 'b.txt' && e[2] >= 3) || (e[2] === 3 && e[0] === 'rename' && e[1] === 'a.txt');
    });
    const deleted = at('gone.txt', 5, 5);
    console.log('create-event', create.length > 0, create.length > 0 ? create[0][0] : '-');
    console.log('write-event', wrote.length > 0);
    console.log('rename-event', renamed.length > 0);
    console.log('delete-event', deleted.length > 0);
    console.log('file-event', fileSeen.length > 0, fileSeen.length > 0 ? fileSeen[0][0] : '-');
    console.log('file-name', fileSeen.length > 0 ? fileSeen[0][1] === 'single.txt' : false);

    watcher.close();
    watcher.close();
    fileWatcher.close();
    const before = seen.length + fileSeen.length;
    fs.writeFileSync(path.join(dir, 'late.txt'), 'x');
    setTimeout(function () {
        console.log('close-silent', seen.length + fileSeen.length === before);
        fs.rmSync(dir, { recursive: true, force: true });
        console.log('done');
    }, 500);
}

setTimeout(proceed, 800);
