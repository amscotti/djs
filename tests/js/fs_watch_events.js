// fs.watch event coverage beyond the single create case in fs_watch.js:
// create, write, rename and delete in a watched directory, watching a single
// file, and silence after close(). Assertions are boolean so the same golden
// holds on Linux (inotify) and macOS (FSEvents/kqueue); FSEvents reports
// some writes as "rename", so write events only assert that an event with the
// filename arrived.
const fs = require('fs');
const path = require('path');
const os = require('os');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'djs-watch-'));
const base = path.basename(dir);
// A watch on a missing path surfaces the OS error code, not EINVAL.
try {
    fs.watch(path.join(dir, 'missing'), function () {});
    console.log('missing-error none');
} catch (e) {
    console.log('missing-error', e.code);
}
const seen = [];
const watcher = fs.watch(dir, function (event, filename) {
    seen.push([event, filename]);
});
const fileSeen = [];
const file = path.join(dir, 'single.txt');
fs.writeFileSync(file, 'x');
const fileWatcher = fs.watch(file, function (event, filename) {
    fileSeen.push([event, filename]);
});

function proceed() {
    fs.writeFileSync(path.join(dir, 'a.txt'), 'one');          // create
    setTimeout(function () {
        fs.writeFileSync(path.join(dir, 'a.txt'), 'two');      // write
        setTimeout(function () {
            fs.renameSync(path.join(dir, 'a.txt'), path.join(dir, 'b.txt'));
            setTimeout(function () {
                fs.appendFileSync(file, 'y');                  // file watch
                setTimeout(function () {
                    fs.unlinkSync(path.join(dir, 'b.txt'));
                    setTimeout(finish, 350);
                }, 600);
            }, 600);
        }, 600);
    }, 600);
}

function finish() {
    const dirEvents = seen.filter(function (e) { return e[1] !== base; });
    const create = dirEvents.filter(function (e) { return e[1] === 'a.txt'; });
    const renamed = dirEvents.filter(function (e) { return e[1] === 'b.txt' || (e[0] === 'rename' && e[1] === 'a.txt'); });
    const deleted = dirEvents.filter(function (e) { return e[1] === 'b.txt'; });
    console.log('create-event', create.length > 0, create.length > 0 ? create[0][0] : '-');
    console.log('rename-event', renamed.length > 0);
    console.log('delete-event', deleted.length > 0);
    console.log('file-event', fileSeen.length > 0, fileSeen.length > 0 ? fileSeen[0][0] : '-');
    console.log('file-name', fileSeen.length > 0 ? fileSeen[0][1] === 'single.txt' : false);

    // close() stops delivery and is idempotent.
    watcher.close();
    watcher.close();
    fileWatcher.close();
    const before = seen.length + fileSeen.length;
    fs.writeFileSync(path.join(dir, 'late.txt'), 'x');
    setTimeout(function () {
        console.log('close-silent', seen.length + fileSeen.length === before);
        fs.rmSync(dir, { recursive: true, force: true });
        console.log('done');
    }, 400);
}

// Give the watchers a moment to become active before mutating.
setTimeout(proceed, 200);
