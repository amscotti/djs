    // ---- fs ------------------------------------------------------------

    function encodingOf(options) {
        if (typeof options === 'string') return options;
        if (options && typeof options === 'object') return options.encoding || undefined;
        return undefined;
    }

    function requireCallback(cb) {
        if (typeof cb !== 'function')
            throw new TypeError('The "cb" argument must be of type function');
        return cb;
    }

    function Stats(raw) {
        this.size = raw.size;
        this.mtimeMs = raw.mtimeMs;
        this.atimeMs = raw.atimeMs;
        this.ctimeMs = raw.ctimeMs;
        this.ino = raw.ino;
        this.dev = raw.dev;
        this.nlink = raw.nlink;
        this.uid = raw.uid;
        this.gid = raw.gid;
        this.blksize = raw.blksize;
        this.blocks = raw.blocks;
        this.rdev = raw.rdev;
        this.birthtimeMs = raw.ctimeMs;
        this.mode = raw.mode;
        this.atime = new Date(raw.atimeMs);
        this.mtime = new Date(raw.mtimeMs);
        this.ctime = new Date(raw.ctimeMs);
        this.birthtime = new Date(this.birthtimeMs);
        this._isFile = raw.isFile;
        this._isDirectory = raw.isDirectory;
        this._isSymbolicLink = raw.isSymbolicLink;
        this._isFIFO = raw.isFIFO;
        this._isSocket = raw.isSocket;
        this._isCharacterDevice = raw.isCharacterDevice;
        this._isBlockDevice = raw.isBlockDevice;
    }
    Stats.prototype.isFile = function () { return !!this._isFile; };
    Stats.prototype.isDirectory = function () { return !!this._isDirectory; };
    Stats.prototype.isSymbolicLink = function () { return !!this._isSymbolicLink; };
    Stats.prototype.isFIFO = function () { return !!this._isFIFO; };
    Stats.prototype.isSocket = function () { return !!this._isSocket; };
    Stats.prototype.isCharacterDevice = function () { return !!this._isCharacterDevice; };
    Stats.prototype.isBlockDevice = function () { return !!this._isBlockDevice; };

    function readResult(data, asText) {
        return asText ? data : new Buffer(data);
    }

    // Strings are written in the requested encoding; Buffer/view inputs pass
    // through untouched. Returns the bytes the native layer should copy.
    function writeData(data, options) {
        if (typeof data === 'string') return Buffer.from(data, encodingOf(options) || 'utf8');
        return data;
    }

    function readFileSync(path, options) {
        var enc = encodingOf(options);
        var buf = new Buffer(__djs.fs.readFileSync(path, false));
        return enc === undefined ? buf : buf.toString(enc);
    }

    function readFile(path, options, callback) {
        var cb = callback;
        var opts = options;
        if (typeof options === 'function') { cb = options; opts = undefined; }
        requireCallback(cb);
        var enc = encodingOf(opts);
        __djs.fs.readFileStart(path, false, function (err, data) {
            if (err) return cb(err);
            var buf = new Buffer(data);
            cb(null, enc === undefined ? buf : buf.toString(enc));
        });
    }

    function modeArg(m) { return typeof m === 'string' ? parseInt(m, 8) : m; }

    function writeModeOf(options) {
        if (options && typeof options === 'object' && options.mode !== undefined) {
            var m = options.mode;
            return typeof m === 'string' ? parseInt(m, 8) : m;
        }
        return 0; // native default: 0666 & umask
    }

    function writeFileSync(path, data, options) {
        __djs.fs.writeFileSync(path, writeData(data, options), false, writeModeOf(options));
    }

    function appendFileSync(path, data, options) {
        __djs.fs.writeFileSync(path, writeData(data, options), true, writeModeOf(options));
    }

    function writeFile(path, data, options, callback) {
        var cb = callback;
        var opts = options;
        if (typeof options === 'function') { cb = options; opts = undefined; }
        requireCallback(cb);
        __djs.fs.writeFileStart(path, writeData(data, opts), false, writeModeOf(opts), function (err) {
            cb(err || null);
        });
    }

    function appendFile(path, data, options, callback) {
        var cb = callback;
        var opts = options;
        if (typeof options === 'function') { cb = options; opts = undefined; }
        requireCallback(cb);
        __djs.fs.writeFileStart(path, writeData(data, opts), true, writeModeOf(opts), function (err) {
            cb(err || null);
        });
    }

    function statSync(path) { return new Stats(__djs.fs.statSync(path)); }

    function stat(path, callback) {
        requireCallback(callback);
        __djs.fs.statStart(path, function (err, raw) {
            if (err) return callback(err);
            callback(null, new Stats(raw));
        });
    }

    // Node's dirent types (Linux d_type values).
    function Dirent(name, type, parentPath) {
        this.name = String(name);
        this.parentPath = parentPath === undefined ? null : String(parentPath);
        this.path = this.parentPath;
        this._type = type;
    }
    Dirent.prototype.isFile = function () { return this._type === 8; };
    Dirent.prototype.isDirectory = function () { return this._type === 4; };
    Dirent.prototype.isSymbolicLink = function () { return this._type === 10; };
    Dirent.prototype.isFIFO = function () { return this._type === 1; };
    Dirent.prototype.isSocket = function () { return this._type === 12; };
    Dirent.prototype.isCharacterDevice = function () { return this._type === 2; };
    Dirent.prototype.isBlockDevice = function () { return this._type === 6; };

    function accessError(code, syscall, path) {
        var e = new Error(code + ': ' + syscall + " '" + path + "'");
        e.code = code;
        e.errno = code === 'EACCES' ? -13 : -2;
        e.syscall = syscall;
        e.path = path;
        return e;
    }

    // Node's access() is a mode-bit probe: F_OK checks existence, the others
    // check the permission bits returned by stat.
    function accessSync(path, mode) {
        var m = mode === undefined ? 0 : Number(mode);
        var st = statSync(path);
        if ((m & 1) && (st.mode & 73) === 0) throw accessError('EACCES', 'access', String(path));
        if ((m & 2) && (st.mode & 146) === 0) throw accessError('EACCES', 'access', String(path));
        if ((m & 4) && (st.mode & 292) === 0) throw accessError('EACCES', 'access', String(path));
        return undefined;
    }

    function access(path, mode, callback) {
        if (typeof mode === 'function') { callback = mode; mode = 0; }
        requireCallback(callback);
        queueMicrotask(function () {
            try { accessSync(path, mode); callback(null); }
            catch (e) { callback(e); }
        });
    }

    function mkdtempSuffix() {
        var chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
        var out = '';
        for (var i = 0; i < 6; i++) out += chars.charAt(Math.floor(Math.random() * chars.length));
        return out;
    }

    function mkdtempSync(prefix) {
        prefix = String(prefix);
        for (var attempt = 0; attempt < 32; attempt++) {
            var candidate = prefix + mkdtempSuffix();
            try { mkdirSync(candidate); return candidate; }
            catch (e) { if (e.code !== 'EEXIST') throw e; }
        }
        throw accessError('EEXIST', 'mkdtemp', prefix);
    }

    function mkdtemp(prefix, callback) {
        requireCallback(callback);
        queueMicrotask(function () {
            try { callback(null, mkdtempSync(prefix)); }
            catch (e) { callback(e); }
        });
    }

    function readdirSync(path, options) {
        if (options && typeof options === 'object' && options.withFileTypes) {
            var flat = __djs.fs.readdirTypesSync(path);
            var out = [];
            for (var i = 0; i < flat.length; i += 2) out.push(new Dirent(flat[i], flat[i + 1], path));
            return out;
        }
        return __djs.fs.readdirSync(path);
    }

    function Dir(dirPath) {
        this.path = String(dirPath);
        this._entries = null;
        this._index = 0;
        this._closed = false;
    }
    Dir.prototype.readSync = function () {
        if (this._closed) return null;
        if (!this._entries) this._entries = __djs.fs.readdirSync(this.path);
        if (this._index >= this._entries.length) return null;
        var name = this._entries[this._index++];
        var full = this.path.replace(/\/$/, '') + '/' + name;
        var kind = null;
        return {
            name: name,
            parentPath: this.path,
            path: full,
            isFile: function () {
                try { if (!kind) kind = __djs.fs.statSync(full); return !!kind.isFile; } catch (e) { return false; }
            },
            isDirectory: function () {
                try { if (!kind) kind = __djs.fs.statSync(full); return !!kind.isDirectory; } catch (e) { return false; }
            }
        };
    };
    Dir.prototype.closeSync = function () { this._closed = true; this._entries = []; };
    Dir.prototype.close = function (cb) {
        this.closeSync();
        if (cb) { queueMicrotask(cb); return undefined; }
        // Node returns a promise when no callback is given, so `await dir.close()`
        // works.
        return Promise.resolve();
    };
    Dir.prototype.readSync = function () {
        if (this._closed) {
            var closed = new Error('Directory handle was closed');
            closed.code = 'ERR_DIR_CLOSED';
            throw closed;
        }
        if (this._entries === null) this._entries = readdirSync(this.path, { withFileTypes: true });
        if (this._index >= this._entries.length) return null;
        var entry = this._entries[this._index];
        this._index += 1;
        // Dirents carry the directory they were read from.
        if (entry && entry.parentPath === null) entry.parentPath = this.path;
        return entry;
    };
    Dir.prototype.read = function (cb) {
        var result = null, error = null;
        try { result = this.readSync(); } catch (e) { error = e; }
        if (typeof cb === 'function') {
            queueMicrotask(function () { cb(error, error ? undefined : result); });
            return undefined;
        }
        return error ? Promise.reject(error) : Promise.resolve(result);
    };
    Dir.prototype[Symbol.asyncIterator] = function () {
        var self = this;
        return {
            next: function () {
                return new Promise(function (resolve, reject) {
                    self.read(function (err, entry) {
                        if (err) reject(err);
                        else resolve(entry === null ? { value: undefined, done: true } : { value: entry, done: false });
                    });
                });
            },
            return: function () {
                self.closeSync();
                return Promise.resolve({ value: undefined, done: true });
            }
        };
    };
    function opendirSync(dirPath) {
        if (!fs.statSync(dirPath).isDirectory()) {
            var e = new Error('ENOTDIR: not a directory');
            e.code = 'ENOTDIR';
            throw e;
        }
        return new Dir(dirPath);
    }
    function opendir(dirPath, options, cb) {
        if (typeof options === 'function') { cb = options; options = {}; }
        requireCallback(cb);
        queueMicrotask(function () {
            try { cb(null, opendirSync(dirPath)); } catch (e) { cb(e); }
        });
    }

    function StatWatcher(file, listener) {
        EventEmitter.call(this);
        this._file = String(file);
        this._listener = listener;
        this._timer = null;
        this._last = null;
        this._closed = false;
    }
    StatWatcher.prototype = Object.create(EventEmitter.prototype);
    StatWatcher.prototype.constructor = StatWatcher;
    StatWatcher.prototype.close = function () {
        if (this._closed) return;
        this._closed = true;
        if (this._timer) clearInterval(this._timer);
        this._timer = null;
        unregisterWatcher(this);
        this.emit('close');
    };
    StatWatcher.prototype._start = function (interval) {
        var self = this;
        var tick = function () {
            if (self._closed) return;
            var cur = null;
            try {
                var st = __djs.fs.statSync(self._file);
                cur = { mtime: st.mtimeMs, size: st.size };
            } catch (e) {
                cur = null;
            }
            if (self._last && cur && (cur.mtime !== self._last.mtime || cur.size !== self._last.size)) {
                self._listener(cur, self._last);
                self.emit('change', cur, self._last);
            }
            self._last = cur;
        };
        tick();
        this._timer = setInterval(tick, interval);
        if (this._timer && typeof this._timer.unref === 'function') this._timer.unref();
    };
    var watchersByFile = Object.create(null);
    function unregisterWatcher(w) {
        var list = watchersByFile[w._file];
        if (!list) return;
        var idx = list.indexOf(w);
        if (idx >= 0) list.splice(idx, 1);
        if (!list.length) delete watchersByFile[w._file];
    }
    function watchFile(file, options, listener) {
        if (typeof options === 'function') { listener = options; options = {}; }
        if (typeof listener !== 'function') throw new TypeError('listener must be a function');
        var w = new StatWatcher(file, listener);
        // Every poller has to be reachable or unwatchFile() is a no-op; it was
        // never registered before, so unwatchFile() silently did nothing.
        var key = String(file);
        (watchersByFile[key] || (watchersByFile[key] = [])).push(w);
        w._start(Number(options && options.interval) || 5007);
        return w;
    }
    function unwatchFile(file, listener) {
        var list = watchersByFile[String(file)];
        if (!list) return;
        // close() unregisters itself, so iterate a copy.
        list.slice().forEach(function (w) {
            if (typeof listener === 'function' && w._listener !== listener) return;
            w.close();
        });
    }

    function readdir(path, options, callback) {
        if (typeof options === 'function') { callback = options; options = undefined; }
        requireCallback(callback);
        if (options && typeof options === 'object' && options.withFileTypes) {
            queueMicrotask(function () {
                try { callback(null, readdirSync(path, options)); }
                catch (e) { callback(e); }
            });
            return;
        }
        __djs.fs.readdirStart(path, function (err, entries) {
            if (err) return callback(err);
            callback(null, entries);
        });
    }

    function modeOf(options) {
        if (typeof options === 'number') return options;
        if (options && typeof options === 'object' && typeof options.mode === 'number')
            return options.mode;
        return 511; // 0777
    }

    function recursiveOf(options) {
        return !!(options && typeof options === 'object' && options.recursive);
    }

    function mkdirSync(path, options) {
        __djs.fs.mkdirSync(path, modeOf(options), recursiveOf(options));
    }

    function mkdir(path, options, callback) {
        var cb = callback;
        if (typeof options === 'function') cb = options;
        requireCallback(cb);
        __djs.fs.mkdirStart(path, modeOf(options), recursiveOf(options),
                            function (err) { cb(err || null); });
    }

    function unlinkSync(path) { __djs.fs.unlinkSync(path); }

    function unlink(path, callback) {
        requireCallback(callback);
        __djs.fs.unlinkStart(path, function (err) { callback(err || null); });
    }

    function renameSync(from, to) { __djs.fs.renameSync(from, to); }

    function rename(from, to, callback) {
        requireCallback(callback);
        __djs.fs.renameStart(from, to, function (err) { callback(err || null); });
    }

    // These numeric values are passed straight to open(2), so they must match
    // the host's <fcntl.h>/<copyfile.h>. Darwin's flag encoding differs from
    // Linux's (O_CREAT is 512, not 64; O_CLOEXEC is 0x01000000).
    var IS_DARWIN = __djs.process.platform() === 'darwin';
    var COPYFILE_EXCL = IS_DARWIN ? 131072 : 1;

    function copyFileSync(src, dest, flags) {
        __djs.fs.copyFileSync(src, dest, !!((flags || 0) & COPYFILE_EXCL));
    }

    function copyFile(src, dest, flags, callback) {
        var cb = callback;
        var mode = flags;
        if (typeof flags === 'function') { cb = flags; mode = 0; }
        requireCallback(cb);
        __djs.fs.copyFileStart(src, dest, !!((mode || 0) & COPYFILE_EXCL),
                               function (err) { cb(err || null); });
    }

    function FSWatcher(listener) {
        EventEmitter.call(this);
        this._listener = listener || null;
        this._id = 0;
        this._closed = false;
        this._ref = true;
    }
    FSWatcher.prototype = Object.create(EventEmitter.prototype);
    FSWatcher.prototype.constructor = FSWatcher;
    FSWatcher.prototype.close = function () {
        if (this._closed) return;
        this._closed = true;
        if (this._id) { __djs.fs.watchClose(this._id); this._id = 0; }
        this.emit('close');
    };
    FSWatcher.prototype.ref = function () {
        this._ref = true;
        if (!this._closed && this._id) __djs.fs.watchSetRef(this._id, true);
        return this;
    };
    FSWatcher.prototype.unref = function () {
        this._ref = false;
        if (!this._closed && this._id) __djs.fs.watchSetRef(this._id, false);
        return this;
    };
    function RecursiveWatcher(root, listener) {
        EventEmitter.call(this);
        this._root = String(root);
        this._listener = listener || null;
        this._closed = false;
        this._watched = Object.create(null);
        this._ids = [];
        this._ref = true;
        this._addDir(this._root);
    }
    RecursiveWatcher.prototype = Object.create(EventEmitter.prototype);
    RecursiveWatcher.prototype.constructor = RecursiveWatcher;
    RecursiveWatcher.prototype._addDir = function (dir) {
        if (this._closed || this._watched[dir]) return;
        var self = this;
        this._watched[dir] = true;
        var id = __djs.fs.watchStart(dir, function (type, filename) {
            if (self._closed) return;
            var full = filename ? pathModule.join(dir, filename) : dir;
            var rel = full === self._root ? "" : full.slice(self._root.length + 1);
            self.emit('change', type, rel);
            if (self._listener) self._listener(type, rel);
            if (type === 'rename') {
                try {
                    var st = statSync(full);
                    if (st.isDirectory()) self._addDir(full);
                } catch (e) {}
            }
        });
        this._ids.push(id);
        if (!this._ref) __djs.fs.watchSetRef(id, false);
        var names;
        try { names = readdirSync(dir); } catch (e) { return; }
        for (var i = 0; i < names.length; i++) {
            var full = pathModule.join(dir, names[i]);
            try {
                var st = statSync(full);
                if (st.isDirectory()) this._addDir(full);
            } catch (e) {}
        }
    };
    RecursiveWatcher.prototype.close = function () {
        if (this._closed) return;
        this._closed = true;
        for (var i = 0; i < this._ids.length; i++) __djs.fs.watchClose(this._ids[i]);
        this._ids = [];
        this.emit('close');
    };
    RecursiveWatcher.prototype.ref = function () {
        this._ref = true;
        if (!this._closed) for (var i = 0; i < this._ids.length; i++) __djs.fs.watchSetRef(this._ids[i], true);
        return this;
    };
    RecursiveWatcher.prototype.unref = function () {
        this._ref = false;
        if (!this._closed) for (var i = 0; i < this._ids.length; i++) __djs.fs.watchSetRef(this._ids[i], false);
        return this;
    };

    function watch(path, options, listener) {
        if (typeof options === 'function') { listener = options; options = {}; }
        if (typeof listener !== 'function') throw new TypeError('listener must be a function');
        var recursive = !!(options && options.recursive);
        // macOS FSEvents supports recursive watching natively; one handle
        // covers the whole tree. Linux/inotify has no recursive primitive, so
        // the prelude walks the tree and adds a watcher per directory.
        if (recursive && __djs.process.platform() !== 'darwin')
            return new RecursiveWatcher(String(path), listener);
        var self = new FSWatcher(listener);
        self._id = __djs.fs.watchStart(String(path), function (type, filename) {
            if (self._closed) return;
            self.emit('change', type, filename);
            if (self._listener) self._listener(type, filename);
        }, recursive);
        if (!self._ref) __djs.fs.watchSetRef(self._id, false);
        return self;
    }

    function rmSync(path, options) {
        __djs.fs.rmSync(path, recursiveOf(options),
                        !!(options && typeof options === 'object' && options.force));
    }

    function rm(path, options, callback) {
        var cb = callback;
        var opts = options;
        if (typeof options === 'function') { cb = options; opts = undefined; }
        requireCallback(cb);
        __djs.fs.rmStart(path, recursiveOf(opts),
                         !!(opts && typeof opts === 'object' && opts.force),
                         function (err) { cb(err || null); });
    }

    function realpathSync(path) { return __djs.fs.realpathSync(path); }

    function realpath(path, callback) {
        requireCallback(callback);
        __djs.fs.realpathStart(path, function (err, resolved) {
            if (err) return callback(err);
            callback(null, resolved);
        });
    }

    function promiseOne(fn, args) {
        return new Promise(function (resolve, reject) {
            fn.apply(null, args.concat([function (err, value) {
                if (err) reject(err); else resolve(value);
            }]));
        });
    }

    var fsPromises = {
        readFile: function (path, options) {
            var enc = encodingOf(options);
            return new Promise(function (resolve, reject) {
                __djs.fs.readFileStart(path, false, function (err, data) {
                    if (err) reject(err);
                    else {
                        var buf = new Buffer(data);
                        resolve(enc === undefined ? buf : buf.toString(enc));
                    }
                });
            });
        },
        writeFile: function (path, data, options) {
            return promiseOne(writeFile, [path, data, options || {}]);
        },
        appendFile: function (path, data, options) {
            return promiseOne(appendFile, [path, data, options || {}]);
        },
        stat: function (path) {
            return new Promise(function (resolve, reject) {
                __djs.fs.statStart(path, function (err, raw) {
                    if (err) reject(err);
                    else resolve(new Stats(raw));
                });
            });
        },
        readdir: function (path, options) {
            return promiseOne(readdir, [path, options]);
        },
        access: function (path, mode) {
            return promiseOne(access, [path, mode]);
        },
        mkdtemp: function (prefix) {
            return promiseOne(mkdtemp, [prefix]);
        },
        mkdir: function (path, options) {
            return promiseOne(mkdir, [path, options || {}]);
        },
        unlink: function (path) {
            return promiseOne(unlink, [path]);
        },
        rename: function (from, to) {
            return promiseOne(rename, [from, to]);
        },
        copyFile: function (src, dest, flags) {
            return promiseOne(copyFile, [src, dest, flags || 0]);
        },
        rm: function (path, options) {
            return promiseOne(rm, [path, options || {}]);
        },
        realpath: function (path) {
            return promiseOne(realpath, [path]);
        }
    };

    var fsObj = {
        readFileSync: readFileSync,
        readFile: readFile,
        writeFileSync: writeFileSync,
        writeFile: writeFile,
        appendFileSync: appendFileSync,
        appendFile: appendFile,
        statSync: statSync,
        stat: stat,
        Dirent: Dirent,
        Stats: Stats,
        accessSync: accessSync,
        access: access,
        mkdtempSync: mkdtempSync,
        mkdtemp: mkdtemp,
        readdirSync: readdirSync,
        readdir: readdir,
        mkdirSync: mkdirSync,
        mkdir: mkdir,
        unlinkSync: unlinkSync,
        unlink: unlink,
        renameSync: renameSync,
        rename: rename,
        copyFileSync: copyFileSync,
        copyFile: copyFile,
        rmSync: rmSync,
        watch: watch,
        FSWatcher: FSWatcher,
        opendir: opendir,
        opendirSync: opendirSync,
        Dir: Dir,
        watchFile: watchFile,
        unwatchFile: unwatchFile,
        rm: rm,
        realpathSync: realpathSync,
        realpath: realpath,
        openSync: function (path, flags, mode) { return __djs.fs.openSync(path, flags, mode === undefined ? 438 : modeArg(mode)); },
        closeSync: function (fd) { __djs.fs.closeSync(fd); },
        readSync: function (fd, buffer, offset, length, position) {
            return __djs.fs.readSync(fd, buffer, offset || 0, length === undefined ? buffer.length - (offset || 0) : length, position === undefined ? null : position);
        },
        writeSync: function (fd, data, offset, length, position) {
            if (typeof data === 'string') {
                var enc = typeof position === 'string' ? position : 'utf8';
                var strBuf = Buffer.from(data, enc);
                var strPos = typeof offset === 'number' ? offset : null;
                return __djs.fs.writeSync(fd, strBuf, 0, strBuf.length, strPos);
            }
            var off = offset || 0;
            var len = length === undefined ? data.length - off : length;
            return __djs.fs.writeSync(fd, data, off, len, position === undefined ? null : position);
        },
        fstatSync: function (fd) { return new Stats(__djs.fs.fstatSync(fd)); },
        lstatSync: function (path) { return new Stats(__djs.fs.lstatSync(path)); },
        chmodSync: function (path, mode) { __djs.fs.chmodSync(path, modeArg(mode)); },
        chownSync: function (path, uid, gid) { __djs.fs.chownSync(path, uid, gid); },
        linkSync: function (from, to) { __djs.fs.linkSync(from, to); },
        symlinkSync: function (target, path) { __djs.fs.symlinkSync(target, path); },
        readlinkSync: function (path) { return __djs.fs.readlinkSync(path); },
        truncateSync: function (path, len) { __djs.fs.truncateSync(path, len); },
        fsyncSync: function (fd) { __djs.fs.fsyncSync(fd); },
        fdatasyncSync: function (fd) { __djs.fs.fdatasyncSync(fd); },
        ftruncateSync: function (fd, len) { __djs.fs.ftruncateSync(fd, len); },
        fchmodSync: function (fd, mode) { __djs.fs.fchmodSync(fd, modeArg(mode)); },
        fchownSync: function (fd, uid, gid) { __djs.fs.fchownSync(fd, uid, gid); },
        existsSync: function (path) {
            try { statSync(path); return true; } catch (e) { return false; }
        },
        constants: {
            COPYFILE_EXCL: COPYFILE_EXCL,
            F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1,
            O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2,
            O_CREAT: IS_DARWIN ? 512 : 64,
            O_EXCL: IS_DARWIN ? 2048 : 128,
            O_TRUNC: IS_DARWIN ? 1024 : 512,
            O_APPEND: IS_DARWIN ? 8 : 1024,
            O_NOFOLLOW: IS_DARWIN ? 256 : 131072,
            O_CLOEXEC: IS_DARWIN ? 16777216 : 524288
        },
        promises: fsPromises
    };

    function cpSync(src, dest, options) {
        options = options || {};
        // lstat first: the link decision must see the link itself. With
        // dereference the classification falls through to the followed
        // target, matching Node.
        var lst = fsObj.lstatSync(src);
        if (lst.isSymbolicLink && lst.isSymbolicLink() && !options.dereference) {
            try { unlinkSync(dest); } catch (e) {}
            fsObj.symlinkSync(fsObj.readlinkSync(src), dest);
            return;
        }
        var st = lst.isSymbolicLink && lst.isSymbolicLink() ? statSync(src) : lst;
        if (st.isDirectory()) {
            if (!options.recursive) throw new Error("cp: directory requires recursive: true");
            mkdirSync(dest, { recursive: true });
            var names = readdirSync(src);
            for (var i = 0; i < names.length; i++) {
                cpSync(pathModule.join(src, names[i]), pathModule.join(dest, names[i]), options);
            }
            return;
        }
        mkdirSync(pathModule.dirname(dest), { recursive: true });
        if (!options.force && fsObj.existsSync(dest)) {
            if (options.errorOnExist) throw new Error("cp: destination exists: " + dest);
            return;
        }
        copyFileSync(src, dest);
    }
    fsObj.cpSync = cpSync;
    fsObj.cp = function (src, dest, options, cb) {
        if (typeof options === "function") { cb = options; options = {}; }
        queueMicrotask(function () {
            try { cpSync(src, dest, options || {}); cb(null); }
            catch (e) { cb(e); }
        });
    };
    fsPromises.cp = function (src, dest, options) {
        return new Promise(function (resolve, reject) {
            fsObj.cp(src, dest, options || {}, function (e) { e ? reject(e) : resolve(); });
        });
    };

    function readvSync(fd, buffers, position) {
        var total = 0, pos = position === undefined || position === null ? null : position;
        for (var i = 0; i < buffers.length; i++) {
            var n = fsObj.readSync(fd, buffers[i], 0, buffers[i].length, pos);
            total += n;
            if (pos !== null) pos += n;
            if (n < buffers[i].length) break;
        }
        return total;
    }
    function writevSync(fd, buffers, position) {
        var total = 0, pos = position === undefined || position === null ? null : position;
        for (var i = 0; i < buffers.length; i++) {
            var n = fsObj.writeSync(fd, buffers[i], 0, buffers[i].length, pos);
            total += n;
            if (pos !== null) pos += n;
            if (n < buffers[i].length) break;
        }
        return total;
    }
    fsObj.readvSync = readvSync;
    fsObj.writevSync = writevSync;
    fsObj.readv = function (fd, buffers, position, cb) {
        if (typeof position === "function") { cb = position; position = null; }
        queueMicrotask(function () {
            try { cb(null, readvSync(fd, buffers, position)); } catch (e) { cb(e); }
        });
    };
    fsObj.writev = function (fd, buffers, position, cb) {
        if (typeof position === "function") { cb = position; position = null; }
        queueMicrotask(function () {
            try { cb(null, writevSync(fd, buffers, position)); } catch (e) { cb(e); }
        });
    };
    fsPromises.readv = function (fd, buffers, position) {
        return new Promise(function (resolve, reject) {
            fsObj.readv(fd, buffers, position, function (e, n) { e ? reject(e) : resolve(n); });
        });
    };
    fsPromises.writev = function (fd, buffers, position) {
        return new Promise(function (resolve, reject) {
            fsObj.writev(fd, buffers, position, function (e, n) { e ? reject(e) : resolve(n); });
        });
    };
    fsObj.openAsBlob = function (path, options) {
        return new Promise(function (resolve, reject) {
            try {
                var buf = readFileSync(path);
                resolve(new Blob([buf], { type: (options && options.type) || "" }));
            } catch (e) { reject(e); }
        });
    };


    // ---- events --------------------------------------------------------

    function EventEmitter() {
        this._events = Object.create(null);
        this._maxListeners = undefined;
    }

    EventEmitter.prototype._add = function (name, fn, once, prepend) {
        if (!this._events) this._events = Object.create(null);
        if (typeof fn !== 'function')
            throw new TypeError('The "listener" argument must be of type function');
        var list = this._events[name];
        if (!list) list = this._events[name] = [];
        var entry = { fn: fn, once: !!once };
        if (prepend) list.unshift(entry); else list.push(entry);
        return this;
    };
    EventEmitter.prototype.on = function (name, fn) { return this._add(name, fn, false, false); };
    EventEmitter.prototype.addListener = EventEmitter.prototype.on;
    EventEmitter.prototype.prependListener = function (name, fn) { return this._add(name, fn, false, true); };
    EventEmitter.prototype.once = function (name, fn) { return this._add(name, fn, true, false); };
    EventEmitter.prototype.prependOnceListener = function (name, fn) { return this._add(name, fn, true, true); };
    EventEmitter.prototype.off = function (name, fn) {
        if (!this._events) return this;
        var list = this._events[name];
        if (!list) return this;
        for (var i = list.length - 1; i >= 0; i--)
            if (list[i].fn === fn || list[i].fn.listener === fn) list.splice(i, 1);
        if (list.length === 0) delete this._events[name];
        return this;
    };
    EventEmitter.prototype.removeListener = EventEmitter.prototype.off;
    EventEmitter.prototype.removeAllListeners = function (name) {
        if (!this._events) this._events = Object.create(null);
        if (name === undefined) this._events = Object.create(null);
        else delete this._events[name];
        return this;
    };
    EventEmitter.prototype.listeners = function (name) {
        if (!this._events) return [];
        return (this._events[name] || []).map(function (e) { return e.fn; });
    };
    EventEmitter.prototype.rawListeners = EventEmitter.prototype.listeners;
    EventEmitter.prototype.listenerCount = function (name) {
        if (!this._events) return 0;
        return (this._events[name] || []).length;
    };
    EventEmitter.prototype.eventNames = function () { return this._events ? Object.keys(this._events) : []; };

    // ---- events module statics ----------------------------------------
    EventEmitter.errorMonitor = Symbol.for('nodejs.errorMonitor');
    var captureRejectionsDefault = false;
    Object.defineProperty(EventEmitter, 'captureRejections', {
        get: function () { return captureRejectionsDefault; },
        set: function (v) { captureRejectionsDefault = !!v; },
        enumerable: true,
        configurable: true
    });
    // Like Node's events.on(): resolve with the listener arguments, reject on error.
    // Node returns an async iterator that yields one array of arguments per
    // event: `for await (const [chunk] of on(stream, 'data'))`. Returning a
    // single promise here broke every consumer that iterates.
    EventEmitter.on = function (emitter, name, options) {
        var buffer = [];
        var waiter = null;
        var done = false;
        var failure = null;
        var signal = options && options.signal;
        function settle() {
            if (!waiter) return;
            if (buffer.length) {
                var w = waiter; waiter = null;
                w.resolve({ done: false, value: buffer.shift() });
            } else if (failure) {
                var f = waiter; waiter = null;
                f.reject(failure);
            } else if (done) {
                var d = waiter; waiter = null;
                d.resolve({ done: true, value: undefined });
            }
        }
        function onEvent() { buffer.push(Array.prototype.slice.call(arguments)); settle(); }
        function onError(err) { failure = err; settle(); }
        function onAbort() {
            done = true;
            var e = new Error('The operation was aborted');
            e.name = 'AbortError';
            e.code = 'ABORT_ERR';
            failure = e;
            settle();
        }
        function cleanup() {
            emitter.removeListener(name, onEvent);
            if (name !== 'error') emitter.removeListener('error', onError);
            if (signal && typeof signal.removeEventListener === 'function')
                signal.removeEventListener('abort', onAbort);
        }
        emitter.on(name, onEvent);
        if (name !== 'error') emitter.on('error', onError);
        if (signal) {
            if (signal.aborted) queueMicrotask(onAbort);
            else if (typeof signal.addEventListener === 'function')
                signal.addEventListener('abort', onAbort);
        }
        return {
            next: function () {
                if (buffer.length) return Promise.resolve({ done: false, value: buffer.shift() });
                if (failure) return Promise.reject(failure);
                if (done) return Promise.resolve({ done: true, value: undefined });
                return new Promise(function (resolve, reject) { waiter = { resolve: resolve, reject: reject }; });
            },
            return: function () {
                done = true;
                if (waiter) { var w = waiter; waiter = null; w.resolve({ done: true, value: undefined }); }
                cleanup();
                return Promise.resolve({ done: true, value: undefined });
            },
            throw: function (err) {
                done = true;
                if (waiter) { var w = waiter; waiter = null; w.reject(err); }
                cleanup();
                return Promise.reject(err);
            },
            [Symbol.asyncIterator]: function () { return this; },
        };
    };
    EventEmitter.getEventListeners = function (emitter, name) {
        if (!emitter) return [];
        var events = emitter._events;
        if (!events) return [];
        if (name !== undefined) return (events[name] || []).map(function (e) { return e.fn; });
        var out = {};
        for (var key in events) out[key] = events[key].map(function (e) { return e.fn; });
        return out;
    };
    EventEmitter.addAbortListener = function (signal, listener) {
        if (signal && typeof signal.addEventListener === 'function') {
            signal.addEventListener('abort', listener);
            return { dispose: function () { signal.removeEventListener('abort', listener); } };
        }
        return { dispose: function () { } };
    };
    EventEmitter.prototype.setMaxListeners = function (n) { this._maxListeners = n; return this; };
    EventEmitter.prototype.getMaxListeners = function () { return this._maxListeners === undefined ? EventEmitter.defaultMaxListeners : this._maxListeners; };
    // events.setMaxListeners(n, ...targets): with no targets it sets the
    // default for emitters created afterwards, as Node does.
    EventEmitter.setMaxListeners = function (n) {
        // Infinity is legal (execa calls setMaxListeners(Infinity, signal)).
        if (typeof n !== 'number' || n < 0 || (n !== Infinity && !Number.isInteger(n)))
            throw new RangeError('The value of "n" is out of range. It must be >= 0. Received ' + n);
        if (arguments.length === 1) { EventEmitter.defaultMaxListeners = n; return; }
        for (var i = 1; i < arguments.length; i++) {
            var target = arguments[i];
            if (target && typeof target.setMaxListeners === 'function') target.setMaxListeners(n);
        }
    };
    EventEmitter.prototype.emit = function (name) {
        var list = this._events ? this._events[name] : undefined;
        if (!list || list.length === 0) {
            if (name === 'error') {
                var err = arguments[1];
                if (err instanceof Error) throw err;
                throw new Error('Unhandled error' + (err === undefined ? '' : ': ' + String(err)));
            }
            return false;
        }
        var args = [];
        for (var i = 1; i < arguments.length; i++) args.push(arguments[i]);
        var copy = list.slice();
        for (var j = 0; j < copy.length; j++) {
            var e = copy[j];
            if (e.once) {
                var idx = list.indexOf(e);
                if (idx >= 0) list.splice(idx, 1);
            }
            e.fn.apply(this, args);
        }
        return true;
    };
    EventEmitter.once = function (emitter, name) {
        return new Promise(function (resolve, reject) {
            function onError(err) { emitter.removeListener(name, onEvent); reject(err); }
            function onEvent() {
                emitter.removeListener('error', onError);
                resolve(Array.prototype.slice.call(arguments));
            }
            emitter.once(name, onEvent);
            emitter.once('error', onError);
        });
    };
    EventEmitter.EventEmitter = EventEmitter;
    EventEmitter.defaultMaxListeners = 10;

