module djs.apis.fs;

import core.stdc.errno : EACCES, EBADF, EEXIST, EFBIG, EINTR, EINVAL, EIO, EISDIR, EMFILE, ENAMETOOLONG, ENOENT, ENOMEM, errno;
import core.stdc.stdio : rename;
import core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memchr, memcpy, strlen;
import core.sys.posix.dirent : DIR, dirent, closedir, opendir, readdir;
import core.sys.posix.fcntl : O_ACCMODE, O_APPEND, O_CREAT, O_EXCL, O_RDONLY, O_RDWR, O_TRUNC, O_WRONLY, open;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
import core.sys.posix.sys.stat : S_ISBLK, S_ISCHR, S_ISDIR, S_ISFIFO, S_ISLNK, S_ISREG, S_ISSOCK,
    chmod, fchmod, fstat, lstat, mkdir, stat, stat_t;
import core.sys.posix.sys.types : off_t, ssize_t;
import core.sys.posix.unistd : chown, close, fchown, fsync, ftruncate, link, pread, pwrite, read, readlink,
    rmdir, symlink, truncate, unlink, write;

import djs.bindings.quickjs;
import djs.platform : Mode, O_CLOEXEC, fdatasync;
import djs.bindings.value;
import djs.loop.libuv;
import djs.registry;
import djs.permissions : Perm, permissionCheck, permissionError, permissionPathIdentity, permissionThrow;
import djs.runtime : Runtime, guarded, newTrackedArrayBuffer, runtimeOf, runtimeReportUncaught;

// The v0.1 read cap. Node's fs.readFile refuses files above 2 GiB; 512 MiB
// keeps the host budget honest for a runtime whose whole footprint is smaller
// than Node's. DJS_MAX_FILE_SIZE can lower it.
enum size_t maxFileSizeDefault = 512 * 1024 * 1024;
// Non-regular files (pipes, character devices) have no trustworthy size, so
// they get a smaller hard cap and fail with EFBIG instead of eating the host.
enum size_t maxNonRegularSize = 16 * 1024 * 1024;

enum FsOp
{
    readOp,
    writeOp,
    appendOp,
    statOp,
    readdirOp,
    mkdirOp,
    unlinkOp,
    renameOp,
    copyOp,
    rmOp,
    realpathOp,
    openOp,
}

// A request owns every byte it touches. For writes this means the input is
// copied before queueing: the JS ArrayBuffer may be detached or collected as
// soon as the call returns. No JSValue is stored here.
//
// Async fs runs blocking POSIX calls on a libuv threadpool thread. That is a
// deliberate deviation from the uv_fs_* wrappers: open/read/write loops are
// simpler here, and the cost (an uncancellable request while it blocks) is
// documented in ARCH §9.4.
struct FsWork
{
    uv_work_t* req;
    Runtime* rt;
    ulong callbackId;
    char* path;
    char* path2; // rename/copy destination, owned
    ubyte* data; // write payload, or read/readdir result
    size_t len;
    size_t outLen;
    int err;
    const(char)* syscall;
    FsOp op;
    int mode;
    int openFlags;
    int fd;
    bool asText;
    bool recursive;
    bool force;
    bool excl;
    long size;
    long mtimeMs;
    long atimeMs;
    long ctimeMs;
    long ino;
    long dev;
    long nlink;
    long blksize;
    long blocks;
    long rdev;
    int uid;
    int gid;
    int isFile;
    int isDir;
    int isSymlink;
    int isFifo;
    int isSocket;
    int isChar;
    int isBlock;
    bool noFollow;
    // Identity of path/path2 as seen by the permission check on the JS
    // thread. The worker compares the opened fd against these; a mismatch
    // means the leaf was swapped after the check (symlink TOCTOU).
    bool ckValid;
    long ckDev;
    long ckIno;
    bool ck2Valid;
    long ck2Dev;
    long ck2Ino;
    bool withTypes; // readdir: prefix each entry with its dirent type
}

// File descriptors issued by this module. User code may only operate on these;
// closing or reading libuv's internal descriptors (epoll, eventfd, signal
// pipes) would abort or corrupt the loop. The table is process-global because
// fs is installed once per runtime; v0.7 networking must join the same table.
private bool[65536] issuedFds;

private bool fdIssued(int fd) @nogc nothrow
{
    return fd >= 0 && fd < cast(int) issuedFds.length && issuedFds[fd];
}

private void fdIssue(int fd) @nogc nothrow
{
    if (fd >= 0 && fd < cast(int) issuedFds.length)
        issuedFds[fd] = true;
}

private void fdRelease(int fd) @nogc nothrow
{
    if (fd >= 0 && fd < cast(int) issuedFds.length)
        issuedFds[fd] = false;
}

private const(char)* errCode(int err) @nogc nothrow
{
    int uvErr = err < 0 ? err : uv_translate_sys_error(err);
    return uv_err_name(uvErr);
}

private const(char)* errMessage(int err) @nogc nothrow
{
    int uvErr = err < 0 ? err : uv_translate_sys_error(err);
    return uv_strerror(uvErr);
}

private JSValue fsError(JSContext* ctx, int err, const(char)* path,
                        const(char)* syscall) @nogc nothrow
{
    JSValue e = makeError(ctx, errMessage(err), errCode(err), path, syscall);
    if (!jsIsException(e))
        setProp(ctx, e, "errno", jsInt(-(err < 0 ? -err : err)));
    return e;
}

private JSValue throwFsError(JSContext* ctx, int err, const(char)* path,
                             const(char)* syscall) @nogc nothrow
{
    JSValue e = fsError(ctx, err, path, syscall);
    if (jsIsException(e))
        return e;
    return throwError(ctx, e);
}

private size_t maxFileSize() @nogc nothrow
{
    import core.stdc.stdlib : getenv;
    const(char)* env = getenv("DJS_MAX_FILE_SIZE");
    if (env is null)
        return maxFileSizeDefault;
    // The variable can only lower the cap. Anything malformed or larger than
    // the default falls back to the default rather than wrapping.
    size_t v = 0;
    for (size_t i = 0; env[i] != 0; ++i)
    {
        if (env[i] < '0' || env[i] > '9')
            return maxFileSizeDefault;
        size_t digit = env[i] - '0';
        if (v > (maxFileSizeDefault - digit) / 10)
            return maxFileSizeDefault;
        v = v * 10 + digit;
    }
    return v > 0 ? v : maxFileSizeDefault;
}

// Growable read loop. Short reads are normal; EOF is the only stopping point.
// Regular files are presized with fstat so a too-large file fails before any
// allocation, and non-regular files (pipes, devices) are capped.
private bool fdIdentityMatches(FsWork* w, int fd, bool second = false) @nogc nothrow
{
    if (second ? !w.ck2Valid : !w.ckValid)
        return true; // nothing identifiable was captured (new file, etc.)
    stat_t st = void;
    if (fstat(fd, &st) != 0)
        return false;
    return st.st_dev == (second ? w.ck2Dev : w.ckDev) &&
           st.st_ino == (second ? w.ck2Ino : w.ckIno);
}

private void doRead(FsWork* w) @nogc nothrow
{
    w.syscall = "open";
    int fd = open(w.path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
    {
        w.err = errno;
        return;
    }
    if (!fdIdentityMatches(w, fd))
    {
        // The leaf changed between the permission check and this open
        // (swapped symlink or rename): what was opened is not what was
        // checked. Fail closed.
        close(fd);
        w.err = EACCES;
        return;
    }
    w.syscall = "read";
    size_t cap = 8192;
    size_t limit = maxNonRegularSize;
    stat_t st = void;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode))
    {
        long size = cast(long) st.st_size;
        if (size < 0 || size > cast(long) maxFileSize())
        {
            w.err = EFBIG;
            close(fd);
            return;
        }
        cap = cast(size_t) size + 1;
        limit = maxFileSize();
    }
    ubyte* buf = cast(ubyte*) malloc(cap);
    if (buf is null)
    {
        w.err = ENOMEM;
        close(fd);
        return;
    }
    size_t len = 0;
    for (;;)
    {
        if (len == cap)
        {
            if (cap >= limit)
            {
                free(buf);
                close(fd);
                w.err = EFBIG;
                return;
            }
            size_t next = cap * 2;
            if (next > limit)
                next = limit;
            if (next <= cap)
            {
                free(buf);
                close(fd);
                w.err = EFBIG;
                return;
            }
            ubyte* grown = cast(ubyte*) realloc(buf, next);
            if (grown is null)
            {
                free(buf);
                close(fd);
                w.err = ENOMEM;
                return;
            }
            buf = grown;
            cap = next;
        }
        ptrdiff_t n = read(fd, buf + len, cap - len);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            w.err = errno;
            free(buf);
            close(fd);
            return;
        }
        if (n == 0)
            break;
        len += cast(size_t) n;
    }
    close(fd);
    w.data = buf;
    w.len = len;
}

private void doWrite(FsWork* w) @nogc nothrow
{
    w.syscall = "open";
    int flags = O_WRONLY | O_CREAT | (w.op == FsOp.appendOp ? O_APPEND : O_TRUNC);
    uint mode = w.mode != 0 ? cast(uint) w.mode : 438; // caller mode or 0666
    int fd = open(w.path, flags | O_CLOEXEC, mode);
    if (fd < 0)
    {
        w.err = errno;
        return;
    }
    if (!fdIdentityMatches(w, fd))
    {
        close(fd);
        w.err = EACCES;
        return;
    }
    w.syscall = "write";
    size_t off = 0;
    while (off < w.len)
    {
        ptrdiff_t n = write(fd, w.data + off, w.len - off);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            w.err = errno;
            close(fd);
            return;
        }
        if (n == 0)
        {
            w.err = EIO;
            close(fd);
            return;
        }
        off += cast(size_t) n;
    }
    w.syscall = "close";
    if (close(fd) != 0)
        w.err = errno;
}

// Darwin's stat_t has st_*timespec rather than the st_*time seconds fields
// POSIX exposes on Linux; pick whichever the platform's struct actually has.
private long statSeconds(ref stat_t st, int which) @nogc nothrow
{
    static if (__traits(hasMember, stat_t, "st_mtimespec"))
    {
        if (which == 0) return cast(long) st.st_atimespec.tv_sec;
        if (which == 1) return cast(long) st.st_mtimespec.tv_sec;
        return cast(long) st.st_ctimespec.tv_sec;
    }
    else
    {
        if (which == 0) return cast(long) st.st_atime;
        if (which == 1) return cast(long) st.st_mtime;
        return cast(long) st.st_ctime;
    }
}

private void fillStat(FsWork* w, stat_t* st) @nogc nothrow
{
    w.size = cast(long) st.st_size;
    w.mtimeMs = statSeconds(*st, 1) * 1000;
    w.atimeMs = statSeconds(*st, 0) * 1000;
    w.ctimeMs = statSeconds(*st, 2) * 1000;
    w.ino = cast(long) st.st_ino;
    w.dev = cast(long) st.st_dev;
    w.nlink = cast(long) st.st_nlink;
    w.blksize = cast(long) st.st_blksize;
    w.blocks = cast(long) st.st_blocks;
    w.rdev = cast(long) st.st_rdev;
    w.uid = cast(int) st.st_uid;
    w.gid = cast(int) st.st_gid;
    w.isFile = S_ISREG(st.st_mode) ? 1 : 0;
    w.isDir = S_ISDIR(st.st_mode) ? 1 : 0;
    w.isSymlink = S_ISLNK(st.st_mode) ? 1 : 0;
    w.isFifo = S_ISFIFO(st.st_mode) ? 1 : 0;
    w.isSocket = S_ISSOCK(st.st_mode) ? 1 : 0;
    w.isChar = S_ISCHR(st.st_mode) ? 1 : 0;
    w.isBlock = S_ISBLK(st.st_mode) ? 1 : 0;
    w.mode = cast(int) st.st_mode;
}

private void doStat(FsWork* w) @nogc nothrow
{
    w.syscall = w.noFollow ? "lstat" : "stat";
    stat_t st = void;
    int rc = w.noFollow ? lstat(w.path, &st) : stat(w.path, &st);
    if (rc != 0)
    {
        w.err = errno;
        return;
    }
    fillStat(w, &st);
}

private void doReaddir(FsWork* w) @nogc nothrow
{
    w.syscall = "scandir";
    DIR* dir = opendir(w.path);
    if (dir is null)
    {
        w.err = errno;
        return;
    }
    size_t cap = 1024;
    ubyte* buf = cast(ubyte*) malloc(cap);
    if (buf is null)
    {
        w.err = ENOMEM;
        closedir(dir);
        return;
    }
    size_t len = 0;
    for (;;)
    {
        dirent* ent = readdir(dir);
        if (ent is null)
            break;
        const(char)* name = (&ent.d_name[0]);
        if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
            continue;
        size_t n = strlen(name);
        size_t need = n + 1 + (w.withTypes ? 1 : 0);
        if (len + need > cap)
        {
            size_t next = cap * 2;
            while (next < need + len)
                next *= 2;
            ubyte* grown = cast(ubyte*) realloc(buf, next);
            if (grown is null)
            {
                w.err = ENOMEM;
                free(buf);
                closedir(dir);
                return;
            }
            buf = grown;
            cap = next;
        }
        if (w.withTypes)
        {
            buf[len] = cast(ubyte) (ent.d_type & 0x0F);
            len += 1;
        }
        memcpy(buf + len, name, n + 1);
        len += n + 1;
    }
    closedir(dir);
    w.data = buf;
    w.outLen = len;
}

private void doMkdir(FsWork* w) @nogc nothrow
{
    w.syscall = "mkdir";
    if (!w.recursive)
    {
        if (mkdir(w.path, cast(Mode) w.mode) != 0)
            w.err = errno;
        return;
    }
    // Create each missing component, tolerating EEXIST at every level. The
    // final component keeps the caller's error (EEXIST included).
    size_t n = strlen(w.path);
    char* tmp = cast(char*) malloc(n + 1);
    if (tmp is null)
    {
        w.err = ENOMEM;
        return;
    }
    memcpy(tmp, w.path, n + 1);
    for (size_t i = 1; i < n; ++i)
    {
        if (tmp[i] != '/')
            continue;
        tmp[i] = 0;
        if (mkdir(tmp, cast(Mode) w.mode) != 0 && errno != EEXIST)
        {
            w.err = errno;
            free(tmp);
            return;
        }
        tmp[i] = '/';
    }
    if (mkdir(tmp, cast(Mode) w.mode) != 0)
    {
        if (errno != EEXIST)
            w.err = errno;
        else
        {
            // EEXIST is only success when the existing entry is a directory;
            // a file or a dangling symlink at the leaf is an error, as in Node.
            stat_t st = void;
            if (stat(tmp, &st) != 0 || !S_ISDIR(st.st_mode))
                w.err = EEXIST;
        }
    }
    free(tmp);
}

private void doUnlink(FsWork* w) @nogc nothrow
{
    w.syscall = "unlink";
    if (unlink(w.path) != 0)
        w.err = errno;
}

private void doRename(FsWork* w) @nogc nothrow
{
    w.syscall = "rename";
    if (w.path2 is null)
    {
        w.err = EINVAL;
        return;
    }
    if (rename(w.path, w.path2) != 0)
        w.err = errno;
}

// Copy the bytes, preserving the source mode. The destination is opened
// without O_TRUNC first so a same-inode destination (same path, hardlink or a
// symlink to the source) is detected before anything can be destroyed.
private void doCopy(FsWork* w) @nogc nothrow
{
    w.syscall = "open";
    int src = open(w.path, O_RDONLY | O_CLOEXEC);
    if (src < 0)
    {
        w.err = errno;
        return;
    }
    if (!fdIdentityMatches(w, src))
    {
        close(src);
        w.err = EACCES;
        return;
    }
    stat_t sst = void;
    if (fstat(src, &sst) != 0)
    {
        w.err = errno;
        close(src);
        return;
    }
    int flags = O_WRONLY | O_CREAT | (w.excl ? O_EXCL : 0);
    int dst = open(w.path2, flags | O_CLOEXEC, 438); // 0666 & umask, then fchmod
    if (dst < 0)
    {
        w.err = errno;
        close(src);
        return;
    }
    if (!fdIdentityMatches(w, dst, true))
    {
        close(src);
        close(dst);
        w.err = EACCES;
        return;
    }
    stat_t dstst = void;
    if (fstat(dst, &dstst) != 0)
    {
        w.err = errno;
        close(src);
        close(dst);
        return;
    }
    if (dstst.st_dev == sst.st_dev && dstst.st_ino == sst.st_ino)
    {
        // Same inode: Node returns success without touching the file. This
        // covers a==b, hardlinks and a destination symlink to the source.
        close(src);
        if (close(dst) != 0)
            w.err = errno;
        return;
    }
    if (ftruncate(dst, 0) != 0)
    {
        w.err = errno;
        close(src);
        close(dst);
        return;
    }
    if (fchmod(dst, cast(uint)(sst.st_mode & 0xFFF)) != 0)
    {
        w.err = errno;
        close(src);
        close(dst);
        return;
    }
    ubyte[64 * 1024] buf = void;
    for (;;)
    {
        w.syscall = "read";
        ssize_t n = read(src, buf.ptr, buf.length);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            w.err = errno;
            break;
        }
        if (n == 0)
            break;
        size_t off = 0;
        while (off < cast(size_t) n)
        {
            w.syscall = "write";
            ssize_t m = write(dst, buf.ptr + off, cast(size_t) n - off);
            if (m < 0)
            {
                if (errno == EINTR)
                    continue;
                w.err = errno;
                break;
            }
            off += cast(size_t) m;
        }
        if (w.err != 0)
            break;
    }
    close(src);
    if (close(dst) != 0 && w.err == 0)
        w.err = errno;
}

private char* joinAlloc(const(char)* dir, const(char)* name) @nogc nothrow
{
    size_t dl = strlen(dir), nl = strlen(name);
    char* p = cast(char*) malloc(dl + nl + 2);
    if (p is null)
        return null;
    memcpy(p, dir, dl);
    p[dl] = '/';
    memcpy(p + dl + 1, name, nl + 1);
    return p;
}

// Deep trees are legitimate; the cap only exists to bound pathological input.
// A read-only pre-scan means an over-deep tree fails before anything is deleted.
private enum int maxRmDepth = 1024;

private int rmDepthCheck(const(char)* path, int depth) @nogc nothrow
{
    if (depth > maxRmDepth)
        return EINVAL;
    stat_t st = void;
    if (lstat(path, &st) != 0)
        return errno;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
        return 0;
    DIR* dir = opendir(path);
    if (dir is null)
        return errno;
    int rc = 0;
    for (;;)
    {
        dirent* ent = readdir(dir);
        if (ent is null)
            break;
        const(char)* name = (&ent.d_name[0]);
        if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
            continue;
        char* child = joinAlloc(path, name);
        if (child is null)
        {
            rc = ENOMEM;
            break;
        }
        rc = rmDepthCheck(child, depth + 1);
        free(child);
        if (rc != 0)
            break;
    }
    closedir(dir);
    return rc;
}

// Remove a tree without following symlinks: lstat decides, so a link to a
// directory is unlinked rather than recursed into.
private int rmTree(const(char)* path, int depth) @nogc nothrow
{
    if (depth > maxRmDepth)
        return EINVAL;
    stat_t st = void;
    if (lstat(path, &st) != 0)
        return errno;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode))
        return unlink(path) == 0 ? 0 : errno;
    DIR* dir = opendir(path);
    if (dir is null)
        return errno;
    int rc = 0;
    for (;;)
    {
        dirent* ent = readdir(dir);
        if (ent is null)
            break;
        const(char)* name = (&ent.d_name[0]);
        if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
            continue;
        char* child = joinAlloc(path, name);
        if (child is null)
        {
            rc = ENOMEM;
            break;
        }
        rc = rmTree(child, depth + 1);
        free(child);
        if (rc != 0)
            break;
    }
    closedir(dir);
    if (rc != 0)
        return rc;
    return rmdir(path) == 0 ? 0 : errno;
}

private void doRm(FsWork* w) @nogc nothrow
{
    w.syscall = "unlink";
    stat_t st = void;
    if (lstat(w.path, &st) != 0)
    {
        w.err = errno;
        if (w.force && w.err == ENOENT)
            w.err = 0;
        return;
    }
    if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode))
    {
        if (!w.recursive)
        {
            w.err = EISDIR;
            return;
        }
        w.syscall = "rmdir";
        int depthErr = rmDepthCheck(w.path, 0);
        w.err = depthErr != 0 ? depthErr : rmTree(w.path, 0);
        return;
    }
    if (unlink(w.path) != 0)
        w.err = errno;
}

private void doRealpath(FsWork* w) @nogc nothrow
{
    w.syscall = "realpath";
    char* resolved = realpath(w.path, null);
    if (resolved is null)
    {
        w.err = errno;
        return;
    }
    w.data = cast(ubyte*) resolved;
    w.outLen = strlen(resolved);
}

private extern(C) void fsWorkCb(uv_work_t* req) nothrow @nogc
{
    FsWork* w = cast(FsWork*) uv_req_get_data(cast(uv_req_t*) req);
    if (w is null)
        return;
    final switch (w.op)
    {
    case FsOp.readOp:
        doRead(w);
        break;
    case FsOp.writeOp:
    case FsOp.appendOp:
        doWrite(w);
        break;
    case FsOp.statOp:
        doStat(w);
        break;
    case FsOp.readdirOp:
        doReaddir(w);
        break;
    case FsOp.mkdirOp:
        doMkdir(w);
        break;
    case FsOp.unlinkOp:
        doUnlink(w);
        break;
    case FsOp.renameOp:
        doRename(w);
        break;
    case FsOp.copyOp:
        doCopy(w);
        break;
    case FsOp.rmOp:
        doRm(w);
        break;
    case FsOp.realpathOp:
        doRealpath(w);
        break;
    case FsOp.openOp:
        w.syscall = "open";
        w.fd = open(w.path, w.openFlags, cast(uint) w.mode);
        if (w.fd < 0)
            w.err = errno;
        else if (!fdIdentityMatches(w, w.fd))
        {
            close(w.fd);
            w.fd = -1;
            w.err = EACCES;
        }
        break;
    }
}

// Build the JS result for a completed request. Returns an owned value.
private JSValue buildResult(JSContext* ctx, FsWork* w) @nogc nothrow
{
    final switch (w.op)
    {
    case FsOp.readOp:
        if (w.asText)
            return JS_NewStringLen(ctx, cast(const(char)*) w.data, w.len);
        return newTrackedArrayBuffer(ctx, w.rt, w.data, w.len);
    case FsOp.statOp:
        JSValue obj = JS_NewObject(ctx);
        if (jsIsException(obj))
            return obj;
        setProp(ctx, obj, "size", jsFloat(cast(double) w.size));
        setProp(ctx, obj, "mtimeMs", jsFloat(cast(double) w.mtimeMs));
        setProp(ctx, obj, "atimeMs", jsFloat(cast(double) w.atimeMs));
        setProp(ctx, obj, "ctimeMs", jsFloat(cast(double) w.ctimeMs));
        setProp(ctx, obj, "ino", jsFloat(cast(double) w.ino));
        setProp(ctx, obj, "dev", jsFloat(cast(double) w.dev));
        setProp(ctx, obj, "nlink", jsFloat(cast(double) w.nlink));
        setProp(ctx, obj, "blksize", jsFloat(cast(double) w.blksize));
        setProp(ctx, obj, "blocks", jsFloat(cast(double) w.blocks));
        setProp(ctx, obj, "rdev", jsFloat(cast(double) w.rdev));
        setProp(ctx, obj, "uid", jsInt(w.uid));
        setProp(ctx, obj, "gid", jsInt(w.gid));
        setProp(ctx, obj, "mode", jsInt(w.mode));
        setProp(ctx, obj, "isFile", jsBool(w.isFile != 0));
        setProp(ctx, obj, "isDirectory", jsBool(w.isDir != 0));
        setProp(ctx, obj, "isSymbolicLink", jsBool(w.isSymlink != 0));
        setProp(ctx, obj, "isFIFO", jsBool(w.isFifo != 0));
        setProp(ctx, obj, "isSocket", jsBool(w.isSocket != 0));
        setProp(ctx, obj, "isCharacterDevice", jsBool(w.isChar != 0));
        setProp(ctx, obj, "isBlockDevice", jsBool(w.isBlock != 0));
        return obj;
    case FsOp.readdirOp:
        JSValue arr = JS_NewArray(ctx);
        if (jsIsException(arr))
            return arr;
        uint index = 0;
        size_t off = 0;
        while (off < w.outLen)
        {
            int type = -1;
            if (w.withTypes)
                type = w.data[off++];
            const(char)* name = cast(const(char)*) (w.data + off);
            size_t n = strlen(name);
            JSValue s = JS_NewStringLen(ctx, name, n);
            if (jsIsException(s) || !setIndex(ctx, arr, index, s))
            {
                JS_FreeValue(ctx, arr);
                return jsException();
            }
            index += 1;
            if (w.withTypes)
            {
                if (!setIndex(ctx, arr, index, jsInt(type)))
                {
                    JS_FreeValue(ctx, arr);
                    return jsException();
                }
                index += 1;
            }
            off += n + 1;
        }
        return arr;
    case FsOp.writeOp:
    case FsOp.appendOp:
    case FsOp.mkdirOp:
    case FsOp.unlinkOp:
    case FsOp.renameOp:
    case FsOp.copyOp:
    case FsOp.rmOp:
        return jsUndefined();
    case FsOp.realpathOp:
        return JS_NewStringLen(ctx, cast(const(char)*) w.data, w.outLen);
    case FsOp.openOp:
        fdIssue(w.fd);
        return jsInt(w.fd);
    }
}

private extern(C) void fsAfterCb(uv_work_t* req, int status) nothrow @nogc
{
    FsWork* w = cast(FsWork*) uv_req_get_data(cast(uv_req_t*) req);
    if (w is null)
    {
        free(req);
        return;
    }
    // The callback owns every buffer plus the request itself; release them in
    // one place, including the early return on a JS exception below.
    scope(exit)
    {
        free(w.path);
        free(w.path2);
        free(w.data);
        free(w.req);
        free(w);
    }
    Runtime* self = w.rt;
    if (status != 0 && w.err == 0)
        w.err = status;

    JSValue fn = jsUndefined();
    bool haveFn = false;
    if (self !is null && !self.shuttingDown && !self.failed && !self.exitRequested &&
        self.ctx !is null)
        haveFn = registryDetach(self.ctx, &self.registry, w.callbackId, &fn, null);

    if (haveFn)
    {
        JSContext* ctx = self.ctx;
        JSValue[2] args;
        args[0] = jsNull();
        args[1] = jsUndefined();
        int argc = 1;

        if (w.err != 0)
        {
            args[0] = fsError(ctx, w.err, w.path, w.syscall !is null ? w.syscall : "open");
        }
        else
        {
            args[1] = buildResult(ctx, w);
            if (jsIsException(args[1]))
            {
                JS_FreeValue(ctx, fn);
                JS_FreeValue(ctx, args[0]);
                runtimeReportUncaught(self, ctx);
                return;
            }
            argc = 2;
        }

        JSValue result = JS_Call(ctx, fn, jsUndefined(), argc, &args[0]);
        JS_FreeValue(ctx, fn);
        for (int i = 0; i < argc; ++i)
            JS_FreeValue(ctx, args[i]);
        if (jsIsException(result))
            runtimeReportUncaught(self, ctx);
        JS_FreeValue(ctx, result);
    }
}

private bool fsOpWrites(FsOp op) pure @safe @nogc nothrow
{
    final switch (op)
    {
    case FsOp.readOp:
    case FsOp.statOp:
    case FsOp.readdirOp:
    case FsOp.realpathOp:
    case FsOp.openOp:
        return false;
    case FsOp.writeOp:
    case FsOp.appendOp:
    case FsOp.mkdirOp:
    case FsOp.unlinkOp:
    case FsOp.renameOp:
    case FsOp.copyOp:
    case FsOp.rmOp:
        return true;
    }
}

// Boundary helper: the engine hands back a view into JS string memory. The
// checks below (string-ness, embedded NULs, length-bounded copy) are what make
// this safe to trust; callers get a malloc'd NUL-terminated copy they own.
private @trusted bool getPath(JSContext* ctx, JSValueConst val, char** dest) @nogc nothrow
{
    if (!jsIsString(val))
    {
        throwTypeError(ctx, "path must be a string");
        return false;
    }
    const(char)* p = null;
    size_t len = 0;
    if (!toStringView(ctx, val, &p, &len))
        return false;
    if (memchr(p, 0, len) !is null)
    {
        JS_FreeCString(ctx, p);
        throwTypeError(ctx, "path must not contain null bytes");
        return false;
    }
    char* copy = cast(char*) malloc(len + 1);
    if (copy is null)
    {
        JS_FreeCString(ctx, p);
        throwInternalError(ctx, "out of memory");
        return false;
    }
    memcpy(copy, p, len);
    copy[len] = 0;
    JS_FreeCString(ctx, p);
    *dest = copy;
    return true;
}

// Copy the JS-level bytes into a malloc buffer owned by the caller. Strings,
// ArrayBuffers, typed arrays and DataViews are accepted; a view contributes
// only its own byte range.
// Boundary helper: string, ArrayBuffer and TypedArray views are all copied
// into an owned buffer, with the source length supplied by the engine.
private @trusted bool copyBytes(JSContext* ctx, JSValueConst val, ubyte** dest,
                                size_t* destLen) @nogc nothrow
{
    const(char)* str = null;
    size_t strLen = 0;
    if (jsIsString(val) && toStringView(ctx, val, &str, &strLen))
    {
        ubyte* buf = cast(ubyte*) malloc(strLen > 0 ? strLen : 1);
        if (buf is null)
        {
            JS_FreeCString(ctx, str);
            throwInternalError(ctx, "out of memory");
            return false;
        }
        if (strLen > 0)
            memcpy(buf, str, strLen);
        JS_FreeCString(ctx, str);
        *dest = buf;
        *destLen = strLen;
        return true;
    }
    if (JS_HasException(ctx))
        return false;

    size_t len = 0;
    ubyte* ptr = null;
    if (JS_IsArrayBuffer(val))
    {
        ptr = JS_GetArrayBuffer(ctx, &len, val);
        if (ptr is null)
        {
            throwTypeError(ctx, "detached ArrayBuffer");
            return false;
        }
        return copyRange(ptr, len, dest, destLen, ctx);
    }

    int taType = JS_GetTypedArrayType(val);
    if (taType >= 0)
    {
        size_t offset = 0;
        size_t viewLen = 0;
        size_t elem = 0;
        JSValue ab = JS_GetTypedArrayBuffer(ctx, val, &offset, &viewLen, &elem);
        if (jsIsException(ab))
            return false;
        size_t abLen = 0;
        ubyte* base = JS_GetArrayBuffer(ctx, &abLen, ab);
        bool ok = base !is null && offset + viewLen <= abLen;
        JS_FreeValue(ctx, ab);
        if (!ok)
        {
            throwTypeError(ctx, "invalid typed array view");
            return false;
        }
        return copyRange(base + offset, viewLen, dest, destLen, ctx);
    }

    // DataView and other ArrayBufferViews expose buffer/byteOffset/byteLength.
    JSValue buffer = JS_GetPropertyStr(ctx, val, "buffer");
    if (!jsIsException(buffer) && JS_IsArrayBuffer(buffer))
    {
        JSValue offVal = JS_GetPropertyStr(ctx, val, "byteOffset");
        JSValue lenVal = JS_GetPropertyStr(ctx, val, "byteLength");
        int off32 = 0, len32 = 0;
        bool ok = !jsIsException(offVal) && !jsIsException(lenVal)
            && toInt32(ctx, offVal, &off32) && toInt32(ctx, lenVal, &len32)
            && off32 >= 0 && len32 >= 0;
        if (!jsIsException(offVal))
            JS_FreeValue(ctx, offVal);
        if (!jsIsException(lenVal))
            JS_FreeValue(ctx, lenVal);
        size_t abLen = 0;
        ubyte* base = ok ? JS_GetArrayBuffer(ctx, &abLen, buffer) : null;
        JS_FreeValue(ctx, buffer);
        if (ok && base !is null && cast(size_t) off32 + cast(size_t) len32 <= abLen)
            return copyRange(base + off32, cast(size_t) len32, dest, destLen, ctx);
        if (JS_HasException(ctx))
            return false;
        throwTypeError(ctx, "invalid ArrayBufferView");
        return false;
    }
    if (!jsIsException(buffer))
        JS_FreeValue(ctx, buffer);
    else if (JS_HasException(ctx))
    {
        JSValue extra = JS_GetException(ctx);
        JS_FreeValue(ctx, extra);
    }

    throwTypeError(ctx, "data must be a string, ArrayBuffer, TypedArray, or DataView");
    return false;
}

// Boundary helper: copies exactly `len` bytes from an engine-owned range.
private @trusted bool copyRange(const(ubyte)* src, size_t len, ubyte** dest,
                                size_t* destLen, JSContext* ctx) @nogc nothrow
{
    ubyte* buf = cast(ubyte*) malloc(len > 0 ? len : 1);
    if (buf is null)
    {
        throwInternalError(ctx, "out of memory");
        return false;
    }
    if (len > 0)
        memcpy(buf, src, len);
    *dest = buf;
    *destLen = len;
    return true;
}

private JSValue resultError(JSContext* ctx, FsWork* w) @nogc nothrow
{
    return throwFsError(ctx, w.err, w.path, w.syscall !is null ? w.syscall : "open");
}

private extern(C) JSValue jsReadFileSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "readFileSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.rt = runtimeOf(ctx);
    w.op = FsOp.readOp;
    w.asText = argc >= 2 && JS_ToBool(ctx, argv[1]) > 0;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    // Every exit below owns both buffers; one place releases them.
    scope(exit)
    {
        free(w.path);
        free(w.data);
    }
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);

    doRead(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return buildResult(ctx, &w);
}

extern(C) JSValue jsReadFileSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsReadFileSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsWriteFileSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                              JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "writeFileSync requires (path, data)");
    FsWork w = void;
    w = FsWork.init;
    w.rt = runtimeOf(ctx);
    w.op = argc >= 3 && JS_ToBool(ctx, argv[2]) > 0 ? FsOp.appendOp : FsOp.writeOp;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
        free(w.data);
    }
    if (!permissionCheck(Perm.write, w.path))
        return permissionThrow(ctx, Perm.write, w.path);
    if (!copyBytes(ctx, argv[1], &w.data, &w.len))
        return jsException();
    if (argc >= 4 && !toInt32(ctx, argv[3], &w.mode))
        return jsException();
    doWrite(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return jsUndefined();
}

extern(C) JSValue jsWriteFileSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsWriteFileSyncImpl(ctx, thisVal, argc, argv);
}


private extern(C) JSValue jsStatfsSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "statfsSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.statOp;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
    }
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);
    statvfs_t st = void;
    int rc = statvfs(w.path, &st);
    int e = errno;
    if (rc != 0)
        return makeError(ctx, "statfs failed", "EIO", null, "statfs");
    JSValue o = JS_NewObject(ctx);
    if (jsIsException(o)) return o;
    JS_SetPropertyStr(ctx, o, "type", jsInt(0));
    JS_SetPropertyStr(ctx, o, "bsize", jsFloat(cast(double) st.f_bsize));
    JS_SetPropertyStr(ctx, o, "blocks", jsFloat(cast(double) st.f_blocks));
    JS_SetPropertyStr(ctx, o, "bfree", jsFloat(cast(double) st.f_bfree));
    JS_SetPropertyStr(ctx, o, "bavail", jsFloat(cast(double) st.f_bavail));
    JS_SetPropertyStr(ctx, o, "files", jsFloat(cast(double) st.f_files));
    JS_SetPropertyStr(ctx, o, "ffree", jsFloat(cast(double) st.f_ffree));
    JS_SetPropertyStr(ctx, o, "fsid", jsFloat(cast(double) st.f_fsid));
    JS_SetPropertyStr(ctx, o, "flag", jsFloat(cast(double) st.f_flag));
    JS_SetPropertyStr(ctx, o, "namemax", jsFloat(cast(double) st.f_namemax));
    return o;
}

extern(C) JSValue jsStatfsSync(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStatfsSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsStatSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "statSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.statOp;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit) free(w.path);
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);
    doStat(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return buildResult(ctx, &w);
}

extern(C) JSValue jsStatSync(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{
    return guarded!jsStatSyncImpl(ctx, thisVal, argc, argv);
}

private JSValue readdirSyncCommon(JSContext* ctx, JSValueConst* argv, int argc, bool withTypes) @nogc nothrow
{
    if (argc < 1)
        return throwTypeError(ctx, "readdirSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.readdirOp;
    w.withTypes = withTypes;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
        free(w.data);
    }
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);
    doReaddir(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return buildResult(ctx, &w);
}

private extern(C) JSValue jsReaddirSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    return readdirSyncCommon(ctx, argv, argc, false);
}

extern(C) JSValue jsReaddirSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsReaddirSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsReaddirTypesSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                                 JSValueConst* argv) nothrow @nogc
{
    return readdirSyncCommon(ctx, argv, argc, true);
}

extern(C) JSValue jsReaddirTypesSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                     JSValueConst* argv) nothrow @nogc
{
    return guarded!jsReaddirTypesSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsMkdirSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "mkdirSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.mkdirOp;
    w.mode = 511;
    if (argc >= 2 && !toInt32(ctx, argv[1], &w.mode))
        return jsException();
    w.recursive = argc >= 3 && JS_ToBool(ctx, argv[2]) > 0;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
    }
    if (!permissionCheck(Perm.write, w.path))
        return permissionThrow(ctx, Perm.write, w.path);
    doMkdir(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return jsUndefined();
}

extern(C) JSValue jsMkdirSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{
    return guarded!jsMkdirSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsUnlinkSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "unlinkSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.unlinkOp;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
    }
    if (!permissionCheck(Perm.write, w.path))
        return permissionThrow(ctx, Perm.write, w.path);
    doUnlink(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    return jsUndefined();
}

extern(C) JSValue jsUnlinkSync(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsUnlinkSyncImpl(ctx, thisVal, argc, argv);
}

private JSValue startFsWork(JSContext* ctx, Runtime* self, FsOp op, char* path,
                            ubyte* data, size_t len, bool asText, int mode,
                            JSValueConst callback, char* path2 = null,
                            bool recursive = false, bool force = false,
                            bool excl = false, int openFlags = 0,
                            bool skipPermission = false) @nogc nothrow
{
    // Async permission denial is delivered through the callback, matching the
    // rest of the async fs error contract. It is invoked before the request is
    // queued; no libuv work starts for a denied operation. The failing side
    // and kind are captured during the checks themselves: re-evaluating a
    // check to build the message could issue a second interactive prompt.
    bool needsWrite = fsOpWrites(op);
    Perm kind = needsWrite ? Perm.write : Perm.read;
    const(char)* bad = path;
    bool allowed = skipPermission || permissionCheck(kind, path);
    if (allowed && path2 !is null && !permissionCheck(Perm.write, path2))
    {
        allowed = false;
        bad = path2;
        kind = Perm.write;
    }
    if (!allowed)
    {
        JSValue err = permissionError(ctx, kind, bad);
        free(path);
        free(path2);
        free(data);
        if (!jsIsUndefined(callback) && JS_IsFunction(ctx, callback))
        {
            JSValue[1] argv = [err];
            JSValue callResult = JS_Call(ctx, callback, jsUndefined(), 1, argv.ptr);
            JS_FreeValue(ctx, err);
            if (jsIsException(callResult))
                return callResult;
            JS_FreeValue(ctx, callResult);
            return jsUndefined();
        }
        JS_FreeValue(ctx, err);
        return jsException();
    }

    FsWork* w = cast(FsWork*) calloc(1, FsWork.sizeof);
    if (w is null)
    {
        free(path);
        free(path2);
        free(data);
        return throwInternalError(ctx, "out of memory");
    }
    w.rt = self;
    w.path = path;
    w.path2 = path2;
    w.data = data;
    w.len = len;
    w.op = op;
    w.asText = asText;
    w.mode = mode;
    w.openFlags = openFlags;
    w.recursive = recursive;
    w.force = force;
    w.excl = excl;
    // Remember what the check saw; the worker re-verifies after open.
    w.ckValid = permissionPathIdentity(path, &w.ckDev, &w.ckIno);
    if (path2 !is null)
        w.ck2Valid = permissionPathIdentity(path2, &w.ck2Dev, &w.ck2Ino);
    w.req = cast(uv_work_t*) malloc(uv_req_size(UV_WORK));
    if (w.req is null)
    {
        free(w.path);
        free(w.path2);
        free(w.data);
        free(w);
        return throwInternalError(ctx, "out of memory");
    }
    uv_req_set_data(cast(uv_req_t*) w.req, w);

    ulong id = registryAdd(ctx, &self.registry, callback, null);
    if (id == 0)
    {
        free(w.path);
        free(w.path2);
        free(w.data);
        free(w.req);
        free(w);
        return throwInternalError(ctx, "callback registry exhausted");
    }
    w.callbackId = id;

    int rc = uv_queue_work(self.loop, w.req, &fsWorkCb, &fsAfterCb);
    if (rc != 0)
    {
        registryRelease(ctx, &self.registry, id);
        free(w.path);
        free(w.path2);
        free(w.data);
        free(w.req);
        free(w);
        return throwInternalError(ctx, uv_strerror(rc));
    }
    return jsUndefined();
}

private Runtime* beginAsync(JSContext* ctx) @nogc nothrow
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || self.shuttingDown)
        return null;
    return self;
}

private extern(C) JSValue jsReadFileStartImpl(JSContext* ctx, JSValueConst, int argc,
                                              JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 3 || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "readFile requires (path, asText, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    int boolRc = argc >= 2 ? JS_ToBool(ctx, argv[1]) : 0;
    if (boolRc < 0)
    {
        free(path);
        return jsException();
    }
    bool asText = boolRc > 0;
    return startFsWork(ctx, self, FsOp.readOp, path, null, 0, asText, 0, argv[2]);
}

extern(C) JSValue jsReadFileStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsReadFileStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsWriteFileStartImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 5 || !JS_IsFunction(ctx, argv[4]))
        return throwTypeError(ctx, "writeFile requires (path, data, append, mode, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    ubyte* data = null;
    size_t len = 0;
    if (!copyBytes(ctx, argv[1], &data, &len))
    {
        free(path);
        return jsException();
    }
    int mode = 0;
    if (!toInt32(ctx, argv[3], &mode))
    {
        free(path);
        free(data);
        return jsException();
    }
    bool append = JS_ToBool(ctx, argv[2]) > 0;
    return startFsWork(ctx, self, append ? FsOp.appendOp : FsOp.writeOp, path, data,
                       len, false, mode, argv[4]);
}

extern(C) JSValue jsWriteFileStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsWriteFileStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsStatStartImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "stat requires (path, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    return startFsWork(ctx, self, FsOp.statOp, path, null, 0, false, 0, argv[1]);
}

extern(C) JSValue jsStatStart(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{
    return guarded!jsStatStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsReaddirStartImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "readdir requires (path, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    return startFsWork(ctx, self, FsOp.readdirOp, path, null, 0, false, 0, argv[1]);
}

extern(C) JSValue jsReaddirStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsReaddirStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsMkdirStartImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 4 || !JS_IsFunction(ctx, argv[3]))
        return throwTypeError(ctx, "mkdir requires (path, mode, recursive, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    int mode = 511;
    if (JS_ToInt32(ctx, &mode, argv[1]) != 0)
    {
        free(path);
        return jsException();
    }
    bool recursive = JS_ToBool(ctx, argv[2]) > 0;
    return startFsWork(ctx, self, FsOp.mkdirOp, path, null, 0, false, mode, argv[3],
                       null, recursive);
}

extern(C) JSValue jsMkdirStart(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsMkdirStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsUnlinkStartImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "unlink requires (path, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    return startFsWork(ctx, self, FsOp.unlinkOp, path, null, 0, false, 0, argv[1]);
}

extern(C) JSValue jsUnlinkStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsUnlinkStartImpl(ctx, thisVal, argc, argv);
}

// ---- rename / copyFile / rm / realpath --------------------------------

private extern(C) JSValue jsRenameSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "renameSync requires (oldPath, newPath)");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.renameOp;
    if (!getPath(ctx, argv[0], &w.path) || !getPath(ctx, argv[1], &w.path2))
    {
        free(w.path);
        free(w.path2);
        return jsException();
    }
    if (!permissionCheck(Perm.write, w.path) || !permissionCheck(Perm.write, w.path2))
    {
        JSValue e = permissionThrow(ctx, Perm.write,
                                    permissionCheck(Perm.write, w.path) ? w.path2 : w.path);
        free(w.path);
        free(w.path2);
        return e;
    }
    doRename(&w);
    JSValue e = w.err != 0 ? resultError(ctx, &w) : jsUndefined();
    free(w.path);
    free(w.path2);
    return e;
}

extern(C) JSValue jsRenameSync(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRenameSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsRenameStartImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 3 || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "rename requires (oldPath, newPath, callback)");
    char* from = null;
    char* to = null;
    if (!getPath(ctx, argv[0], &from) || !getPath(ctx, argv[1], &to))
    {
        free(from);
        free(to);
        return jsException();
    }
    return startFsWork(ctx, self, FsOp.renameOp, from, null, 0, false, 0,
                       argv[2], to);
}

extern(C) JSValue jsRenameStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRenameStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsCopyFileSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "copyFileSync requires (src, dest)");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.copyOp;
    w.excl = argc >= 3 && JS_ToBool(ctx, argv[2]) > 0;
    if (!getPath(ctx, argv[0], &w.path) || !getPath(ctx, argv[1], &w.path2))
    {
        free(w.path);
        free(w.path2);
        return jsException();
    }
    if (!permissionCheck(Perm.write, w.path) || !permissionCheck(Perm.write, w.path2))
    {
        JSValue e = permissionThrow(ctx, Perm.write,
                                    permissionCheck(Perm.write, w.path) ? w.path2 : w.path);
        free(w.path);
        free(w.path2);
        return e;
    }
    doCopy(&w);
    JSValue e = w.err != 0 ? resultError(ctx, &w) : jsUndefined();
    free(w.path);
    free(w.path2);
    return e;
}

extern(C) JSValue jsCopyFileSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsCopyFileSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsCopyFileStartImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 4 || !JS_IsFunction(ctx, argv[3]))
        return throwTypeError(ctx, "copyFile requires (src, dest, excl, callback)");
    char* from = null;
    char* to = null;
    if (!getPath(ctx, argv[0], &from) || !getPath(ctx, argv[1], &to))
    {
        free(from);
        free(to);
        return jsException();
    }
    bool excl = JS_ToBool(ctx, argv[2]) > 0;
    return startFsWork(ctx, self, FsOp.copyOp, from, null, 0, false, 0,
                       argv[3], to, false, false, excl);
}

extern(C) JSValue jsCopyFileStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsCopyFileStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsRmSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "rmSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.rmOp;
    w.recursive = argc >= 2 && JS_ToBool(ctx, argv[1]) > 0;
    w.force = argc >= 3 && JS_ToBool(ctx, argv[2]) > 0;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
    }
    if (!permissionCheck(Perm.write, w.path))
        return permissionThrow(ctx, Perm.write, w.path);
    doRm(&w);
    JSValue e = w.err != 0 ? resultError(ctx, &w) : jsUndefined();
    return e;
}

extern(C) JSValue jsRmSync(JSContext* ctx, JSValueConst thisVal, int argc,
                           JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRmSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsRmStartImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 4 || !JS_IsFunction(ctx, argv[3]))
        return throwTypeError(ctx, "rm requires (path, recursive, force, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    bool recursive = JS_ToBool(ctx, argv[1]) > 0;
    bool force = JS_ToBool(ctx, argv[2]) > 0;
    return startFsWork(ctx, self, FsOp.rmOp, path, null, 0, false, 0, argv[3],
                       null, recursive, force);
}

extern(C) JSValue jsRmStart(JSContext* ctx, JSValueConst thisVal, int argc,
                            JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRmStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsRealpathSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "realpathSync requires a path");
    FsWork w = void;
    w = FsWork.init;
    w.op = FsOp.realpathOp;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
        free(w.data);
    }
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);
    doRealpath(&w);
    JSValue v = w.err != 0 ? resultError(ctx, &w) : buildResult(ctx, &w);
    return v;
}

extern(C) JSValue jsRealpathSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRealpathSyncImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsRealpathStartImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "realpath requires (path, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    return startFsWork(ctx, self, FsOp.realpathOp, path, null, 0, false, 0, argv[1]);
}

extern(C) JSValue jsRealpathStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRealpathStartImpl(ctx, thisVal, argc, argv);
}


// ---- v0.6 fd, mode and link surface -------------------------------

private bool parseOpenFlags(JSContext* ctx, JSValueConst v, int* flags,
                            bool* wantsRead, bool* wantsWrite) @nogc nothrow
{
    *wantsRead = false;
    *wantsWrite = false;
    if (jsIsString(v))
    {
        const(char)* f = null;
        size_t n = 0;
        if (!toStringView(ctx, v, &f, &n))
            return false;
        if (n == 1 && f[0] == 'r') { *flags = O_RDONLY; *wantsRead = true; }
        else if (n == 2 && f[0] == 'r' && f[1] == '+') { *flags = O_RDWR; *wantsRead = *wantsWrite = true; }
        else if (n == 1 && f[0] == 'w') { *flags = O_WRONLY | O_CREAT | O_TRUNC; *wantsWrite = true; }
        else if (n == 2 && f[0] == 'w' && f[1] == '+') { *flags = O_RDWR | O_CREAT | O_TRUNC; *wantsRead = *wantsWrite = true; }
        else if (n == 1 && f[0] == 'a') { *flags = O_WRONLY | O_CREAT | O_APPEND; *wantsWrite = true; }
        else if (n == 2 && f[0] == 'a' && f[1] == '+') { *flags = O_RDWR | O_CREAT | O_APPEND; *wantsRead = *wantsWrite = true; }
        else if ((n == 2 || n == 3) && f[0] == 'w' && f[1] == 'x')
        {
            *flags = O_WRONLY | O_CREAT | O_TRUNC | O_EXCL;
            *wantsWrite = true;
            if (n == 3 && f[2] != '+')
            {
                JS_FreeCString(ctx, f);
                throwTypeError(ctx, "invalid open flags");
                return false;
            }
            if (n == 3) { *flags = O_RDWR | O_CREAT | O_TRUNC | O_EXCL; *wantsRead = *wantsWrite = true; }
        }
        else if ((n == 2 || n == 3) && f[0] == 'a' && f[1] == 'x')
        {
            *flags = O_WRONLY | O_CREAT | O_APPEND | O_EXCL;
            *wantsWrite = true;
            if (n == 3 && f[2] != '+')
            {
                JS_FreeCString(ctx, f);
                throwTypeError(ctx, "invalid open flags");
                return false;
            }
            if (n == 3) { *flags = O_RDWR | O_CREAT | O_APPEND | O_EXCL; *wantsRead = *wantsWrite = true; }
        }
        else
        {
            JS_FreeCString(ctx, f);
            throwTypeError(ctx, "unsupported open flags");
            return false;
        }
        JS_FreeCString(ctx, f);
        *flags |= O_CLOEXEC;
        return true;
    }
    int n = 0;
    if (!toInt32(ctx, v, &n))
        return false;
    int acc = n & O_ACCMODE;
    if (acc == 3)
    {
        throwTypeError(ctx, "invalid access mode in open flags");
        return false;
    }
    *flags = n | O_CLOEXEC;
    *wantsRead = acc == O_RDONLY || acc == O_RDWR;
    *wantsWrite = acc == O_WRONLY || acc == O_RDWR ||
        (n & (O_CREAT | O_TRUNC | O_APPEND)) != 0;
    return true;
}

private extern(C) JSValue jsOpenSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "openSync requires (path, flags)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    int flags = 0;
    bool wantsRead = false, wantsWrite = false;
    if (!parseOpenFlags(ctx, argv[1], &flags, &wantsRead, &wantsWrite))
    { free(path); return jsException(); }
    if (wantsRead && !permissionCheck(Perm.read, path))
    {
        JSValue e = permissionThrow(ctx, Perm.read, path);
        free(path);
        return e;
    }
    if (wantsWrite && !permissionCheck(Perm.write, path))
    {
        JSValue e = permissionThrow(ctx, Perm.write, path);
        free(path);
        return e;
    }
    int mode = 438; // 0666
    if (argc >= 3 && !toInt32(ctx, argv[2], &mode))
    { free(path); return jsException(); }
    int fd = open(path, flags, mode);
    int err = errno;
    if (fd < 0)
    {
        JSValue e = throwFsError(ctx, err, path, "open");
        free(path);
        return e;
    }
    free(path);
    if (fd >= cast(int) issuedFds.length)
    {
        close(fd);
        return throwFsError(ctx, EMFILE, "", "open");
    }
    fdIssue(fd);
    return jsInt(fd);
}

extern(C) JSValue jsOpenSync(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{ return guarded!jsOpenSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCloseSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &fd))
        return throwTypeError(ctx, "closeSync requires a file descriptor");
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "close");
    if (close(fd) != 0)
        return throwFsError(ctx, errno, "", "close");
    fdRelease(fd);
    return jsUndefined();
}
extern(C) JSValue jsCloseSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsCloseSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsReadSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "readSync requires (fd, buffer)");
    int fd = 0, offset = 0, length = -1;
    long position = -1;
    if (!toFd(ctx, argv[0], &fd))
        return jsException();
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "read");
    size_t blen = 0;
    ubyte* ptr = mutableBytes(ctx, argv[1], &blen);
    if (ptr is null)
        return throwTypeError(ctx, "readSync buffer must be a Uint8Array");
    if (argc >= 3 && !toCount(ctx, argv[2], &offset)) return jsException();
    if (argc >= 4 && !toCount(ctx, argv[3], &length)) return jsException();
    if (argc >= 5 && !toPosition(ctx, argv[4], &position)) return jsException();
    if (length < 0) length = cast(int) blen - offset;
    if (offset < 0 || length < 0 || cast(size_t) offset + cast(size_t) length > blen)
        return throwRangeError(ctx, "readSync offset/length out of range");
    ssize_t n;
    do
        n = position >= 0 ? pread(fd, ptr + offset, cast(size_t) length, cast(off_t) position)
                          : read(fd, ptr + offset, cast(size_t) length);
    while (n < 0 && errno == EINTR);
    if (n < 0)
        return throwFsError(ctx, errno, "", "read");
    return jsInt(cast(int) n);
}
extern(C) JSValue jsReadSync(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{ return guarded!jsReadSyncImpl(ctx, thisVal, argc, argv); }

private ubyte* mutableBytes(JSContext* ctx, JSValueConst val, size_t* len) @nogc nothrow
{
    ubyte* direct = JS_GetUint8Array(ctx, len, val);
    if (direct !is null)
        return direct;
    if (JS_HasException(ctx))
    {
        JSValue exc = JS_GetException(ctx);
        JS_FreeValue(ctx, exc);
    }
    int type = JS_GetTypedArrayType(val);
    if (type < 0)
        return null;
    size_t byteOffset = 0, viewLen = 0, abLen = 0, elem = 0;
    JSValue ab = JS_GetTypedArrayBuffer(ctx, val, &byteOffset, &viewLen, &elem);
    if (jsIsException(ab))
        return null;
    ubyte* base = JS_GetArrayBuffer(ctx, &abLen, ab);
    JS_FreeValue(ctx, ab);
    if (base is null || byteOffset + viewLen > abLen)
        return null;
    *len = viewLen;
    return base + byteOffset;
}

private bool toPosition(JSContext* ctx, JSValueConst v, long* dest) @nogc nothrow
{
    if (jsIsNull(v) || jsIsUndefined(v))
    {
        *dest = -1;
        return true;
    }
    double d = 0;
    if (JS_ToFloat64(ctx, &d, v) != 0)
        return false;
    if (!(d >= 0) || d > 9.007199254740992e15 || d != cast(long) d)
    {
        throwRangeError(ctx, "position must be a non-negative safe integer");
        return false;
    }
    *dest = cast(long) d;
    return true;
}

private bool toFd(JSContext* ctx, JSValueConst v, int* dest) @nogc nothrow
{
    double d = 0;
    if (JS_ToFloat64(ctx, &d, v) != 0)
        return false;
    if (!(d >= 0) || d > 65535.0 || d != cast(int) d)
    {
        throwRangeError(ctx, "file descriptor must be a non-negative integer");
        return false;
    }
    *dest = cast(int) d;
    return true;
}

private bool toCount(JSContext* ctx, JSValueConst v, int* dest) @nogc nothrow
{
    double d = 0;
    if (JS_ToFloat64(ctx, &d, v) != 0)
        return false;
    if (!(d >= 0) || d > 2147483647.0 || d != cast(int) d)
    {
        throwRangeError(ctx, "value must be a non-negative 32-bit integer");
        return false;
    }
    *dest = cast(int) d;
    return true;
}

private extern(C) JSValue jsWriteSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "writeSync requires (fd, buffer)");
    int fd = 0;
    if (!toFd(ctx, argv[0], &fd))
        return jsException();
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "write");
    size_t blen = 0;
    ubyte* bytes = mutableBytes(ctx, argv[1], &blen);
    if (bytes is null)
        return throwTypeError(ctx, "writeSync buffer must be a Uint8Array");
    int offset = 0, length = -1;
    long position = -1;
    if (argc >= 3 && !toCount(ctx, argv[2], &offset)) return jsException();
    if (argc >= 4 && !toCount(ctx, argv[3], &length)) return jsException();
    if (argc >= 5 && !toPosition(ctx, argv[4], &position)) return jsException();
    if (length < 0) length = cast(int) blen - offset;
    if (offset < 0 || length < 0 || cast(size_t) offset + cast(size_t) length > blen)
        return throwRangeError(ctx, "writeSync offset/length out of range");
    ssize_t n;
    do
        n = position >= 0 ? pwrite(fd, bytes + offset, cast(size_t) length, cast(off_t) position)
                          : write(fd, bytes + offset, cast(size_t) length);
    while (n < 0 && errno == EINTR);
    if (n < 0)
        return throwFsError(ctx, errno, "", "write");
    return jsInt(cast(int) n);
}
extern(C) JSValue jsWriteSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsWriteSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsFstatSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    if (argc < 1 || !toFd(ctx, argv[0], &fd))
        return throwTypeError(ctx, "fstatSync requires a file descriptor");
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "fstat");
    stat_t st = void;
    if (fstat(fd, &st) != 0)
        return throwFsError(ctx, errno, "", "fstat");
    FsWork w = FsWork.init;
    w.op = FsOp.statOp;
    fillStat(&w, &st);
    return buildResult(ctx, &w);
}
extern(C) JSValue jsFstatSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsFstatSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsLstatSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "lstatSync requires a path");
    FsWork w = FsWork.init;
    w.op = FsOp.statOp;
    w.noFollow = true;
    if (!getPath(ctx, argv[0], &w.path))
        return jsException();
    scope(exit)
    {
        free(w.path);
    }
    if (!permissionCheck(Perm.read, w.path))
        return permissionThrow(ctx, Perm.read, w.path);
    doStat(&w);
    if (w.err != 0)
        return resultError(ctx, &w);
    JSValue v = buildResult(ctx, &w);
    return v;
}
extern(C) JSValue jsLstatSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsLstatSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChmodSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "chmodSync requires (path, mode)");
    char* path = null;
    int mode = 0;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    if (!toInt32(ctx, argv[1], &mode)) { free(path); return jsException(); }
    if (!permissionCheck(Perm.write, path))
    { JSValue e = permissionThrow(ctx, Perm.write, path); free(path); return e; }
    int rc = chmod(path, cast(Mode) mode);
    int err = errno;
    if (rc != 0)
    {
        JSValue e = throwFsError(ctx, err, path, "chmod");
        free(path);
        return e;
    }
    free(path);
    return jsUndefined();
}
extern(C) JSValue jsChmodSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsChmodSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChownSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 3)
        return throwTypeError(ctx, "chownSync requires (path, uid, gid)");
    char* path = null;
    int uid = 0, gid = 0;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    if (!toInt32(ctx, argv[1], &uid) || !toInt32(ctx, argv[2], &gid) || uid < 0 || gid < 0)
    { free(path); return throwRangeError(ctx, "uid/gid must be non-negative"); }
    if (!permissionCheck(Perm.write, path))
    { JSValue e = permissionThrow(ctx, Perm.write, path); free(path); return e; }
    int rc = chown(path, cast(uint) uid, cast(uint) gid);
    int err = errno;
    if (rc != 0)
    {
        JSValue e = throwFsError(ctx, err, path, "chown");
        free(path);
        return e;
    }
    free(path);
    return jsUndefined();
}
extern(C) JSValue jsChownSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsChownSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsLinkSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "linkSync requires (existingPath, newPath)");
    char* from = null;
    char* to = null;
    if (!getPath(ctx, argv[0], &from)) return jsException();
    if (!getPath(ctx, argv[1], &to)) { free(from); return jsException(); }
    // A hard link shares the inode with `from`, so a link created inside a
    // write scope must not make `from` writable through the new path. Both
    // ends need the write grant (Deno's rule for op_link_sync).
    if (!permissionCheck(Perm.write, from))
    { JSValue e = permissionThrow(ctx, Perm.write, from); free(from); free(to); return e; }
    if (!permissionCheck(Perm.write, to))
    { JSValue e = permissionThrow(ctx, Perm.write, to); free(from); free(to); return e; }
    int rc = link(from, to);
    int err = errno;
    if (rc != 0)
    {
        JSValue e = throwFsError(ctx, err, to, "link");
        free(from); free(to);
        return e;
    }
    free(from); free(to);
    return jsUndefined();
}
extern(C) JSValue jsLinkSync(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{ return guarded!jsLinkSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsSymlinkSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "symlinkSync requires (target, path)");
    char* target = null;
    char* path = null;
    if (!getPath(ctx, argv[0], &target)) return jsException();
    if (!getPath(ctx, argv[1], &path)) { free(target); return jsException(); }
    if (!permissionCheck(Perm.write, path))
    { JSValue e = permissionThrow(ctx, Perm.write, path); free(target); free(path); return e; }
    int rc = symlink(target, path);
    int err = errno;
    if (rc != 0)
    {
        JSValue e = throwFsError(ctx, err, path, "symlink");
        free(target); free(path);
        return e;
    }
    free(target); free(path);
    return jsUndefined();
}
extern(C) JSValue jsSymlinkSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{ return guarded!jsSymlinkSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsReadlinkSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "readlinkSync requires a path");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    if (!permissionCheck(Perm.read, path))
    { JSValue e = permissionThrow(ctx, Perm.read, path); free(path); return e; }
    size_t cap = 256;
    char* buf = cast(char*) malloc(cap);
    if (buf is null) { free(path); return throwInternalError(ctx, "out of memory"); }
    for (;;)
    {
        ssize_t n = readlink(path, buf, cap);
        if (n < 0)
        {
            int err = errno;
            free(buf); free(path);
            return throwFsError(ctx, err, "", "readlink");
        }
        if (cast(size_t) n < cap)
        {
            JSValue v = JS_NewStringLen(ctx, buf, cast(size_t) n);
            free(buf); free(path);
            return v;
        }
        if (cap >= 1024 * 1024)
        {
            free(buf); free(path);
            return throwFsError(ctx, ENAMETOOLONG, "", "readlink");
        }
        cap *= 2;
        char* grown = cast(char*) realloc(buf, cap);
        if (grown is null) { free(buf); free(path); return throwInternalError(ctx, "out of memory"); }
        buf = grown;
    }
}
extern(C) JSValue jsReadlinkSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{ return guarded!jsReadlinkSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTruncateSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "truncateSync requires (path, len)");
    char* path = null;
    long len = 0;
    if (!getPath(ctx, argv[0], &path)) return jsException();
    if (!toPosition(ctx, argv[1], &len) || len < 0) { free(path); return jsException(); }
    if (!permissionCheck(Perm.write, path))
    { JSValue e = permissionThrow(ctx, Perm.write, path); free(path); return e; }
    int rc = truncate(path, cast(off_t) len);
    int err = errno;
    if (rc != 0)
    {
        JSValue e = throwFsError(ctx, err, path, "truncate");
        free(path);
        return e;
    }
    free(path);
    return jsUndefined();
}
extern(C) JSValue jsTruncateSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{ return guarded!jsTruncateSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsFsyncSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    if (argc < 1 || !toFd(ctx, argv[0], &fd))
        return throwTypeError(ctx, "fsyncSync requires a file descriptor");
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "fsync");
    if (fsync(fd) != 0)
        return throwFsError(ctx, errno, "", "fsync");
    return jsUndefined();
}
extern(C) JSValue jsFsyncSync(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsFsyncSyncImpl(ctx, thisVal, argc, argv); }


private extern(C) JSValue jsFtruncateSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    long len = 0;
    if (argc < 2 || !toFd(ctx, argv[0], &fd) || !toPosition(ctx, argv[1], &len) || len < 0)
        return jsException();
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "ftruncate");
    if (ftruncate(fd, cast(off_t) len) != 0)
        return throwFsError(ctx, errno, "", "ftruncate");
    return jsUndefined();
}
extern(C) JSValue jsFtruncateSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{ return guarded!jsFtruncateSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsFchmodSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    int fd = 0, mode = 0;
    if (argc < 2 || !toFd(ctx, argv[0], &fd) || !toInt32(ctx, argv[1], &mode))
        return jsException();
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "fchmod");
    if (fchmod(fd, cast(Mode) mode) != 0)
        return throwFsError(ctx, errno, "", "fchmod");
    return jsUndefined();
}
extern(C) JSValue jsFchmodSync(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{ return guarded!jsFchmodSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsFchownSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    int fd = 0, uid = 0, gid = 0;
    if (argc < 3 || !toFd(ctx, argv[0], &fd) || !toInt32(ctx, argv[1], &uid) || !toInt32(ctx, argv[2], &gid))
        return jsException();
    if (uid < 0 || gid < 0)
        return throwRangeError(ctx, "uid/gid must be non-negative");
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "fchown");
    if (fchown(fd, cast(uint) uid, cast(uint) gid) != 0)
        return throwFsError(ctx, errno, "", "fchown");
    return jsUndefined();
}
extern(C) JSValue jsFchownSync(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{ return guarded!jsFchownSyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsFdatasyncSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    if (argc < 1 || !toFd(ctx, argv[0], &fd))
        return jsException();
    if (!fdIssued(fd))
        return throwFsError(ctx, EBADF, "", "fdatasync");
    if (fdatasync(fd) != 0)
        return throwFsError(ctx, errno, "", "fdatasync");
    return jsUndefined();
}
extern(C) JSValue jsFdatasyncSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{ return guarded!jsFdatasyncSyncImpl(ctx, thisVal, argc, argv); }


private extern(C) JSValue jsOpenStartImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    Runtime* self = beginAsync(ctx);
    if (self is null)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 4 || !JS_IsFunction(ctx, argv[3]))
        return throwTypeError(ctx, "open requires (path, flags, mode, callback)");
    char* path = null;
    if (!getPath(ctx, argv[0], &path))
        return jsException();
    int flags = 0, mode = 438;
    bool wantsRead = false, wantsWrite = false;
    if (!parseOpenFlags(ctx, argv[1], &flags, &wantsRead, &wantsWrite) ||
        !toInt32(ctx, argv[2], &mode))
    {
        free(path);
        return jsException();
    }
    if (wantsRead && !permissionCheck(Perm.read, path))
    {
        JSValue e = permissionThrow(ctx, Perm.read, path);
        free(path);
        return e;
    }
    if (wantsWrite && !permissionCheck(Perm.write, path))
    {
        JSValue e = permissionThrow(ctx, Perm.write, path);
        free(path);
        return e;
    }
    return startFsWork(ctx, self, FsOp.openOp, path, null, 0, false, mode, argv[3],
                       null, false, false, false, flags, true);
}
extern(C) JSValue jsOpenStart(JSContext* ctx, JSValueConst thisVal, int argc,
                              JSValueConst* argv) nothrow @nogc
{ return guarded!jsOpenStartImpl(ctx, thisVal, argc, argv); }


// ---- fs.watch (libuv fs events) -------------------------------------------
//
// One uv_fs_event handle per native watcher: libuv uses inotify on Linux and
// FSEvents (directories) or kqueue (files) on macOS. The JavaScript contract
// is unchanged: the listener receives (eventType, filename) where eventType
// is "change" for content changes and "rename" for create/delete/move.
// libuv may report both in one event; rename wins, matching Node.
//
// Watchers live in a dynamic doubly linked list, not a fixed table: recursive
// watching creates one watcher per directory on Linux, and applications can
// legitimately watch more than the old 32-handle cap. A slot is unlinked as
// soon as close() is called, but stays allocated until libuv runs its close
// callback (the handle's data points at it).

private struct WatchSlot
{
    bool closing;
    int id;
    uv_fs_event_t* ev;
    Runtime* rt;
    ulong cb;
    WatchSlot* prev;
    WatchSlot* next;
}

private __gshared WatchSlot* watchHead;
private __gshared int nextWatchId = 1;

private void watchLink(WatchSlot* w) @nogc nothrow
{
    w.prev = null;
    w.next = watchHead;
    if (watchHead !is null) watchHead.prev = w;
    watchHead = w;
}

private void watchUnlink(WatchSlot* w) @nogc nothrow
{
    if (w.prev !is null) w.prev.next = w.next;
    else watchHead = w.next;
    if (w.next !is null) w.next.prev = w.prev;
    w.prev = null;
    w.next = null;
}

private WatchSlot* watchFind(int id) @nogc nothrow
{
    for (WatchSlot* w = watchHead; w !is null; w = w.next)
        if (w.id == id) return w;
    return null;
}

private bool watchCall(Runtime* rt, ulong cb, int argc, JSValueConst* argv) @nogc nothrow
{
    CallbackSlot* slot = registryLookup(&rt.registry, cb);
    if (slot is null) return false;
    JSValue fn = JS_DupValue(rt.ctx, slot.fn);
    JSValue r = JS_Call(rt.ctx, fn, jsUndefined(), argc, argv);
    JS_FreeValue(rt.ctx, fn);
    if (jsIsException(r))
    {
        JS_FreeValue(rt.ctx, r);
        runtimeReportUncaught(rt, rt.ctx);
        return false;
    }
    JS_FreeValue(rt.ctx, r);
    return true;
}

private extern(C) void watchHandleClosed(uv_handle_t* h) nothrow @nogc
{
    WatchSlot* w = cast(WatchSlot*) uv_handle_get_data(h);
    free(h);
    free(w);
}

private extern(C) void watchEventCb(uv_fs_event_t* h, const(char)* filename,
                                    int events, int status) nothrow @nogc
{
    WatchSlot* w = cast(WatchSlot*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (w is null || w.closing || status < 0)
        return;
    JSValue[2] argv = void;
    const(char)* ev = (events & UV_RENAME) != 0 ? "rename" : "change";
    argv[0] = JS_NewStringLen(w.rt.ctx, ev, strlen(ev));
    argv[1] = (filename !is null && filename[0] != 0)
        ? JS_NewStringLen(w.rt.ctx, filename, strlen(filename))
        : jsNull();
    watchCall(w.rt, w.cb, 2, argv.ptr);
    JS_FreeValue(w.rt.ctx, argv[0]);
    if (!jsIsNull(argv[1])) JS_FreeValue(w.rt.ctx, argv[1]);
}

private extern(C) JSValue jsWatchStartImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "watch requires (path, callback)");
    const(char)* path = null; size_t plen = 0;
    if (!toStringView(ctx, argv[0], &path, &plen)) return jsException();
    scope(exit) JS_FreeCString(ctx, path);
    if (!permissionCheck(Perm.read, path)) return permissionThrow(ctx, Perm.read, path);
    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");

    bool recursive = argc >= 3 && JS_ToBool(ctx, argv[2]) > 0;
    int watchFlags = 0;
    version (OSX)
        if (recursive) watchFlags = UV_FS_EVENT_RECURSIVE;

    WatchSlot* w = cast(WatchSlot*) calloc(1, WatchSlot.sizeof);
    if (w is null) return throwInternalError(ctx, "out of memory");
    uv_fs_event_t* ev = cast(uv_fs_event_t*) malloc(uv_handle_size(UV_FS_EVENT));
    if (ev is null)
    {
        free(w);
        return throwInternalError(ctx, "out of memory");
    }
    int rc = uv_fs_event_init(rt.loop, ev);
    if (rc != 0)
    {
        free(ev);
        free(w);
        return throwInternalError(ctx, "watch init failed");
    }
    w.id = nextWatchId++;
    if (nextWatchId == 0) nextWatchId = 1;
    w.ev = ev;
    w.rt = rt;
    uv_handle_set_data(cast(uv_handle_t*) ev, w);
    watchLink(w);
    ulong cb = registryAdd(ctx, &rt.registry, argv[1], null);
    if (cb == 0)
    {
        // The handle is initialized, so close it instead of free()ing it.
        watchUnlink(w);
        w.closing = true;
        uv_close(cast(uv_handle_t*) ev, &watchHandleClosed);
        return throwInternalError(ctx, "callback registry exhausted");
    }
    w.cb = cb;
    rc = uv_fs_event_start(ev, &watchEventCb, path, watchFlags);
    if (rc != 0)
    {
        watchUnlink(w);
        w.closing = true;
        registryRelease(ctx, &rt.registry, cb);
        w.cb = 0;
        uv_close(cast(uv_handle_t*) ev, &watchHandleClosed);
        // uv_fs_event_start returns a negative libuv code (on Unix,
        // -errno). throwFsError expects a positive errno.
        int sysErr = uv_translate_sys_error(rc);
        if (sysErr < 0) sysErr = -sysErr;
        if (sysErr <= 0) sysErr = EINVAL;
        return throwFsError(ctx, sysErr, path, "watch");
    }
    return jsInt(w.id);
}
extern(C) JSValue jsWatchStart(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsWatchStartImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsWatchCloseImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "watchClose requires an id");
    WatchSlot* w = watchFind(id);
    if (w is null) return throwTypeError(ctx, "invalid watcher");
    // close() is idempotent. The slot is unlinked immediately so a second
    // call cannot find it and uv_close the same handle twice.
    watchUnlink(w);
    w.closing = true;
    if (w.cb != 0) { registryRelease(ctx, &w.rt.registry, w.cb); w.cb = 0; }
    if (w.ev !is null)
    {
        // Safe from inside the event callback: libuv stops delivery and
        // frees the handle through the close callback.
        uv_fs_event_stop(w.ev);
        uv_close(cast(uv_handle_t*) w.ev, &watchHandleClosed);
    }
    else
        free(w);
    return jsUndefined();
}
extern(C) JSValue jsWatchClose(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsWatchCloseImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsWatchSetRefImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "watchSetRef requires an id");
    bool on = argc >= 2 && JS_ToBool(ctx, argv[1]) > 0;
    WatchSlot* w = watchFind(id);
    if (w !is null && w.ev !is null)
    {
        if (on) uv_ref(cast(uv_handle_t*) w.ev);
        else uv_unref(cast(uv_handle_t*) w.ev);
    }
    return jsUndefined();
}
extern(C) JSValue jsWatchSetRef(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsWatchSetRefImpl(ctx, thisVal, argc, argv); }

// Close every watcher owned by this runtime. Teardown drains the loop, which
// runs the close callbacks and frees the slots.
void fsCloseAll(Runtime* self) @nogc nothrow
{
    WatchSlot* w = watchHead;
    while (w !is null)
    {
        WatchSlot* next = w.next;
        if (w.rt is self)
        {
            watchUnlink(w);
            w.closing = true;
            if (w.cb != 0) { registryRelease(self.ctx, &self.registry, w.cb); w.cb = 0; }
            if (w.ev !is null)
            {
                uv_fs_event_stop(w.ev);
                uv_close(cast(uv_handle_t*) w.ev, &watchHandleClosed);
            }
            else
                free(w);
        }
        w = next;
    }
}

bool installFs(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "readFileSync", &jsReadFileSync, 2)
        && addNativeFunction(ctx, obj, "writeFileSync", &jsWriteFileSync, 4)
        && addNativeFunction(ctx, obj, "statSync", &jsStatSync, 1)
        && addNativeFunction(ctx, obj, "readdirSync", &jsReaddirSync, 1)
        && addNativeFunction(ctx, obj, "mkdirSync", &jsMkdirSync, 3)
        && addNativeFunction(ctx, obj, "unlinkSync", &jsUnlinkSync, 1)
        && addNativeFunction(ctx, obj, "renameSync", &jsRenameSync, 3)
        && addNativeFunction(ctx, obj, "copyFileSync", &jsCopyFileSync, 3)
        && addNativeFunction(ctx, obj, "rmSync", &jsRmSync, 3)
        && addNativeFunction(ctx, obj, "watchStart", &jsWatchStart, 2)
        && addNativeFunction(ctx, obj, "watchClose", &jsWatchClose, 1)
        && addNativeFunction(ctx, obj, "watchSetRef", &jsWatchSetRef, 2)
        && addNativeFunction(ctx, obj, "readdirTypesSync", &jsReaddirTypesSync, 1)
        && addNativeFunction(ctx, obj, "realpathSync", &jsRealpathSync, 1)
        && addNativeFunction(ctx, obj, "readFileStart", &jsReadFileStart, 3)
        && addNativeFunction(ctx, obj, "writeFileStart", &jsWriteFileStart, 5)
        && addNativeFunction(ctx, obj, "statStart", &jsStatStart, 2)
        && addNativeFunction(ctx, obj, "readdirStart", &jsReaddirStart, 2)
        && addNativeFunction(ctx, obj, "mkdirStart", &jsMkdirStart, 4)
        && addNativeFunction(ctx, obj, "unlinkStart", &jsUnlinkStart, 2)
        && addNativeFunction(ctx, obj, "renameStart", &jsRenameStart, 3)
        && addNativeFunction(ctx, obj, "copyFileStart", &jsCopyFileStart, 4)
        && addNativeFunction(ctx, obj, "rmStart", &jsRmStart, 4)
        && addNativeFunction(ctx, obj, "realpathStart", &jsRealpathStart, 2)
        && addNativeFunction(ctx, obj, "openSync", &jsOpenSync, 3)
        && addNativeFunction(ctx, obj, "closeSync", &jsCloseSync, 1)
        && addNativeFunction(ctx, obj, "readSync", &jsReadSync, 5)
        && addNativeFunction(ctx, obj, "writeSync", &jsWriteSync, 5)
        && addNativeFunction(ctx, obj, "fstatSync", &jsFstatSync, 1)
        && addNativeFunction(ctx, obj, "lstatSync", &jsLstatSync, 1)
        && addNativeFunction(ctx, obj, "chmodSync", &jsChmodSync, 2)
        && addNativeFunction(ctx, obj, "chownSync", &jsChownSync, 3)
        && addNativeFunction(ctx, obj, "linkSync", &jsLinkSync, 2)
        && addNativeFunction(ctx, obj, "symlinkSync", &jsSymlinkSync, 3)
        && addNativeFunction(ctx, obj, "readlinkSync", &jsReadlinkSync, 1)
        && addNativeFunction(ctx, obj, "truncateSync", &jsTruncateSync, 2)
        && addNativeFunction(ctx, obj, "fsyncSync", &jsFsyncSync, 1)
        && addNativeFunction(ctx, obj, "ftruncateSync", &jsFtruncateSync, 2)
        && addNativeFunction(ctx, obj, "fchmodSync", &jsFchmodSync, 2)
        && addNativeFunction(ctx, obj, "fchownSync", &jsFchownSync, 3)
        && addNativeFunction(ctx, obj, "fdatasyncSync", &jsFdatasyncSync, 1)
        && addNativeFunction(ctx, obj, "openStart", &jsOpenStart, 4)
        && addNativeFunction(ctx, obj, "statfsSync", &jsStatfsSync, 1);
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "fs", obj) > 0;
}

@safe unittest
{
    assert(fsOpWrites(FsOp.writeOp));
    assert(fsOpWrites(FsOp.appendOp));
    assert(fsOpWrites(FsOp.mkdirOp));
    assert(!fsOpWrites(FsOp.readOp));
    assert(!fsOpWrites(FsOp.statOp));
    assert(!fsOpWrites(FsOp.readdirOp));
    assert(!fsOpWrites(FsOp.openOp));
}
