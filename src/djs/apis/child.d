module djs.apis.child;

// v0.8 child processes. spawnSync/execSync run fork+exec with polled pipes in
// the calling thread; the run permission is checked on the exact command path
// before fork ("sh" additionally accepts a /bin/sh grant).

import core.stdc.errno : EAGAIN, EINTR, EWOULDBLOCK, errno;
import core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memcpy, memmove, strcmp, strlen;
import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD, F_SETFL, O_NONBLOCK, fcntl;
import core.sys.posix.poll : POLLERR, POLLHUP, POLLIN, POLLOUT, nfds_t, poll, pollfd;
import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG, waitpid;
import core.sys.posix.unistd : _exit, chdir, close, dup2, environ, execvp, fork, pipe, read, write;

extern(C) int execvpe(const(char)* file, char** argv, char** envp) nothrow @nogc;
import core.sys.posix.sys.types : pid_t, ssize_t;
import core.sys.posix.sys.stat : S_ISDIR, stat, stat_t;
import core.sys.posix.time : CLOCK_MONOTONIC, clock_gettime, timespec;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.permissions : Perm, permissionCheck, permissionDenied, permissionHas, permissionThrow;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.loop.libuv;

private double monotonicMs() @nogc nothrow
{
    timespec ts = void;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return cast(double) ts.tv_sec * 1000.0 + cast(double) ts.tv_nsec / 1_000_000.0;
}

private struct Buf
{
    char* p;
    size_t len;
    size_t cap;
    bool failed;
}

private void bufAdd(Buf* b, const(char)* data, size_t n) @nogc nothrow
{
    if (b.failed || n == 0) return;
    if (b.len + n + 1 > b.cap)
    {
        size_t cap = b.cap == 0 ? 4096 : b.cap;
        while (cap < b.len + n + 1) cap *= 2;
        char* np = cast(char*) realloc(b.p, cap);
        if (np is null) { b.failed = true; return; }
        b.p = np; b.cap = cap;
    }
    memcpy(b.p + b.len, data, n);
    b.len += n;
    b.p[b.len] = 0;
}

private bool runAllowed(const(char)* file) @nogc nothrow
{
    if (strcmp(file, "sh") == 0 && permissionDenied(Perm.run, "/bin/sh"))
        return false;
    if (permissionCheck(Perm.run, file))
        return true;
    if (permissionDenied(Perm.run, file))
        return false;
    // execSync runs "sh" through PATH. Accept the conventional absolute grant
    // for that same shell as an alias; every other command must match the
    // exact path string. Matching a bare name against any path with that
    // basename would let a writable /tmp/echo stand in for /bin/echo. The
    // alias is probed with the side-effect-free query: a prompt was already
    // offered (and declined) for the original name.
    if (strcmp(file, "sh") == 0 && !permissionDenied(Perm.run, "/bin/sh") &&
        permissionHas(Perm.run, "/bin/sh"))
        return true;
    return false;
}

private void setNonBlocking(int fd) @nogc nothrow
{
    if (fd >= 0)
        fcntl(fd, F_SETFL, O_NONBLOCK);
}

// Child pipes are inherited across fork unless every descriptor is marked
// close-on-exec. The descriptors are duplicated onto 0/1/2 before exec, which
// clears the flag on the copies, so marking the originals is safe.
private void closeOnExec(int fd) @nogc nothrow
{
    if (fd >= 0)
        fcntl(fd, F_SETFD, FD_CLOEXEC);
}

private void makePipePair(int[2]* fds) @nogc nothrow
{
    closeOnExec((*fds)[0]);
    closeOnExec((*fds)[1]);
}

// Returns true on EOF or a hard read error, false when the read would block.
// The caller keeps the descriptor open until EOF so a later poll can retry.
private bool readFd(int fd, Buf* outBuf) @nogc nothrow
{
    char[16384] tmp = void;
    while (true)
    {
        ssize_t n = read(fd, tmp.ptr, tmp.length);
        if (n > 0) { bufAdd(outBuf, tmp.ptr, cast(size_t) n); continue; }
        if (n == 0) return true;
        if (errno == EINTR) continue;
        return errno != EAGAIN && errno != EWOULDBLOCK;
    }
}

private bool isDirectory(const(char)* path) @nogc nothrow
{
    stat_t st = void;
    if (stat(path, &st) != 0)
        return false;
    return S_ISDIR(st.st_mode) != 0;
}

private void freeSyncArgs(JSContext* ctx, const(char)* fileJs, char* shellCmd,
                          char** args, int argCount, const(char)* cwd,
                          const(char)* input) @nogc nothrow
{
    if (cwd !is null) JS_FreeCString(ctx, cwd);
    if (input !is null) JS_FreeCString(ctx, input);
    if (fileJs !is null) JS_FreeCString(ctx, fileJs);
    free(shellCmd);
    if (args !is null)
    {
        for (int i = 1; i <= argCount; ++i)
            if (args[i] !is null) JS_FreeCString(ctx, args[i]);
        free(args);
    }
}

private extern(C) JSValue jsChildSpawnSyncImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "spawnSync requires (file, args)");
    const(char)* fileJs = JS_ToCStringLen2(ctx, null, argv[0], false);
    if (fileJs is null) return jsException();

    int argCount = 0;
    JSValue lenVal = JS_GetPropertyStr(ctx, argv[1], "length");
    if (!toInt32(ctx, lenVal, &argCount)) argCount = 0;
    JS_FreeValue(ctx, lenVal);
    if (argCount < 0) argCount = 0;
    char** args = cast(char**) calloc(cast(size_t) argCount + 2, (char*).sizeof);
    if (args is null) { JS_FreeCString(ctx, fileJs); return throwInternalError(ctx, "out of memory"); }
    args[0] = cast(char*) fileJs;
    for (int i = 0; i < argCount; ++i)
    {
        JSValue v = JS_GetPropertyUint32(ctx, argv[1], cast(uint) i);
        args[i + 1] = cast(char*) JS_ToCStringLen2(ctx, null, v, false);
        JS_FreeValue(ctx, v);
        if (args[i + 1] is null)
        {
            // A conversion failure (Symbol, throwing toString) leaves an
            // exception pending. Do not fork with a truncated argv.
            freeSyncArgs(ctx, fileJs, null, args, argCount, null, null);
            return jsException();
        }
    }

    bool shell = false;
    const(char)* cwd = null;
    const(char)* input = null;
    size_t inputLen = 0;
    int timeoutMs = 0;
    size_t maxBuffer = 1024 * 1024;
    if (argc > 2 && jsIsObject(argv[2]))
    {
        JSValue sh = JS_GetPropertyStr(ctx, argv[2], "shell");
        shell = JS_ToBool(ctx, sh) > 0;
        JS_FreeValue(ctx, sh);
        JSValue c = JS_GetPropertyStr(ctx, argv[2], "cwd");
        if (jsIsString(c)) cwd = JS_ToCStringLen2(ctx, null, c, false);
        JS_FreeValue(ctx, c);
        if (cwd is null && JS_HasException(ctx))
        {
            freeSyncArgs(ctx, fileJs, null, args, argCount, null, null);
            return jsException();
        }
        JSValue inputVal = JS_GetPropertyStr(ctx, argv[2], "input");
        if (jsIsString(inputVal)) input = JS_ToCStringLen2(ctx, &inputLen, inputVal, false);
        JS_FreeValue(ctx, inputVal);
        if (input is null && JS_HasException(ctx))
        {
            freeSyncArgs(ctx, fileJs, null, args, argCount, cwd, null);
            return jsException();
        }
        JSValue tv = JS_GetPropertyStr(ctx, argv[2], "timeout");
        if (!jsIsUndefined(tv))
        {
            int v = 0;
            if (toInt32(ctx, tv, &v) && v > 0) timeoutMs = v;
        }
        JS_FreeValue(ctx, tv);
        JSValue mv = JS_GetPropertyStr(ctx, argv[2], "maxBuffer");
        if (!jsIsUndefined(mv))
        {
            int v = 0;
            if (toInt32(ctx, mv, &v) && v > 0) maxBuffer = cast(size_t) v;
        }
        JS_FreeValue(ctx, mv);
    }

    if (cwd !is null && cwd[0] != 0 && !isDirectory(cwd))
    {
        JSValue e = makeError(ctx, "cwd is not a directory", "ENOENT", cwd, "chdir");
        freeSyncArgs(ctx, fileJs, null, args, argCount, cwd, input);
        return throwError(ctx, e);
    }

    // shell:true runs /bin/sh -c "exec <file> <args...>". The argv handed to
    // execvp() is separate from `args` so the JS-owned argument strings are
    // released exactly once.
    char* shellCmd = null;
    const(char)* execFile = fileJs;
    char** execArgs = args;
    if (shell)
    {
        size_t total = 5 + strlen(fileJs) + 1;
        for (int i = 0; i < argCount; ++i)
            total += strlen(args[i + 1]) + 1;
        shellCmd = cast(char*) malloc(total);
        if (shellCmd is null)
        {
            freeSyncArgs(ctx, fileJs, null, args, argCount, cwd, input);
            return throwInternalError(ctx, "out of memory");
        }
        size_t at = 0;
        const(char)* prefix = "exec ";
        memcpy(shellCmd, prefix, 5); at = 5;
        for (size_t i = 0; fileJs[i] != 0; ++i) shellCmd[at++] = fileJs[i];
        for (int i = 0; i < argCount; ++i)
        {
            shellCmd[at++] = ' ';
            for (size_t j = 0; args[i + 1][j] != 0; ++j) shellCmd[at++] = args[i + 1][j];
        }
        shellCmd[at] = 0;
        char*[4] shArgv = [cast(char*) "/bin/sh", cast(char*) "-c", shellCmd, null];
        execFile = "/bin/sh";
        execArgs = shArgv.ptr;
    }

    if (!runAllowed(execFile))
    {
        JSValue e = permissionThrow(ctx, Perm.run, execFile);
        freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
        return e;
    }

    int[2] outPipe = void;
    int[2] errPipe = void;
    int[2] inPipe = void;
    if (pipe(outPipe) != 0)
    {
        freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&outPipe);
    if (pipe(errPipe) != 0)
    {
        close(outPipe[0]); close(outPipe[1]);
        freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&errPipe);
    if (pipe(inPipe) != 0)
    {
        close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1]);
        freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&inPipe);

    pid_t pid = fork();
    if (pid < 0)
    {
        close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1]); close(inPipe[0]); close(inPipe[1]);
        freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
        return throwInternalError(ctx, "fork failed");
    }
    if (pid == 0)
    {
        dup2(inPipe[0], 0);
        dup2(outPipe[1], 1);
        dup2(errPipe[1], 2);
        close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1]); close(inPipe[0]); close(inPipe[1]);
        if (cwd !is null && cwd[0] != 0) chdir(cwd);
        execvp(execArgs[0], execArgs);
        _exit(127);
    }
    close(outPipe[1]); close(errPipe[1]); close(inPipe[0]);

    setNonBlocking(outPipe[0]);
    setNonBlocking(errPipe[0]);
    setNonBlocking(inPipe[1]);

    Buf outBuf = Buf.init;
    Buf errBuf = Buf.init;
    bool timedOut = false, overflow = false;
    double deadline = timeoutMs > 0 ? monotonicMs() + timeoutMs : 0;
    bool outOpen = true, errOpen = true;
    bool inOpen = input !is null && inputLen > 0;
    size_t inOff = 0;
    if (!inOpen) { close(inPipe[1]); inPipe[1] = -1; }

    // stdin is drained through poll() alongside the two output pipes: a
    // blocking write here would deadlock as soon as the child fills stdout.
    while (outOpen || errOpen || inOpen)
    {
        pollfd[3] fds = void;
        int nfds = 0;
        int outIdx = -1, errIdx = -1, inIdx = -1;
        if (outOpen) { fds[nfds].fd = outPipe[0]; fds[nfds].events = POLLIN; outIdx = nfds++; }
        if (errOpen) { fds[nfds].fd = errPipe[0]; fds[nfds].events = POLLIN; errIdx = nfds++; }
        if (inOpen) { fds[nfds].fd = inPipe[1]; fds[nfds].events = POLLOUT; inIdx = nfds++; }
        int waitMs = -1;
        if (timeoutMs > 0)
        {
            double left = deadline - monotonicMs();
            waitMs = left > 0 ? cast(int) left : 0;
        }
        int pr = poll(fds.ptr, cast(nfds_t) nfds, waitMs);
        if (pr < 0) { if (errno == EINTR) continue; break; }
        if (timeoutMs > 0 && monotonicMs() >= deadline)
        {
            timedOut = true;
            kill(pid, SIGKILL);
            break;
        }
        if (inOpen && (fds[inIdx].revents & (POLLOUT | POLLERR | POLLHUP)) != 0)
        {
            ssize_t n = write(inPipe[1], input + inOff, inputLen - inOff);
            if (n > 0) inOff += cast(size_t) n;
            else if (n < 0 && errno == EINTR) {}
            else inOpen = false;
            if (inOff >= inputLen) inOpen = false;
            // Close the write end as soon as the child has every byte: the
            // child's read() only returns 0 (EOF) when no writer remains.
            if (!inOpen) { close(inPipe[1]); inPipe[1] = -1; }
        }
        if (outOpen && (fds[outIdx].revents & (POLLIN | POLLERR | POLLHUP)) != 0)
        {
            if (readFd(outPipe[0], &outBuf)) outOpen = false;
        }
        if (errOpen && (fds[errIdx].revents & (POLLIN | POLLERR | POLLHUP)) != 0)
        {
            if (readFd(errPipe[0], &errBuf)) errOpen = false;
        }
        if (outBuf.len + errBuf.len > maxBuffer)
        {
            overflow = true;
            kill(pid, SIGKILL);
            break;
        }
    }
    close(outPipe[0]); close(errPipe[0]);
    if (inPipe[1] >= 0) close(inPipe[1]);
    if (outBuf.len > maxBuffer) outBuf.len = maxBuffer;
    if (errBuf.len > maxBuffer) errBuf.len = maxBuffer;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
    int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;

    JSValue result = JS_NewObject(ctx);
    if (timedOut || overflow)
    {
        JS_SetPropertyStr(ctx, result, "status", jsNull());
        JS_SetPropertyStr(ctx, result, "signal", newString(ctx, "SIGKILL"));
        JSValue err = makeError(ctx,
            timedOut ? "spawnSync timed out" : "spawnSync maxBuffer exceeded",
            timedOut ? "ETIMEDOUT" : "ERR_CHILD_PROCESS_STDIO_MAXBUFFER",
            null, "spawnSync");
        JS_SetPropertyStr(ctx, result, "error", err);
    }
    else
        JS_SetPropertyStr(ctx, result, "status", jsInt(code));
    JS_SetPropertyStr(ctx, result, "signal", sig == 0 ? jsNull() : jsInt(sig));
    JS_SetPropertyStr(ctx, result, "stdout", JS_NewStringLen(ctx, outBuf.p !is null ? outBuf.p : "", outBuf.len));
    JS_SetPropertyStr(ctx, result, "stderr", JS_NewStringLen(ctx, errBuf.p !is null ? errBuf.p : "", errBuf.len));
    if (timedOut || overflow)
        JS_SetPropertyStr(ctx, result, "signal", newString(ctx, "SIGKILL"));
    free(outBuf.p); free(errBuf.p);
    freeSyncArgs(ctx, fileJs, shellCmd, args, argCount, cwd, input);
    return result;
}
extern(C) JSValue jsChildSpawnSync(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildSpawnSyncImpl(ctx, thisVal, argc, argv); }


private enum int maxChildren = 64;

private struct Child
{
    bool used;
    pid_t pid;
    int inFd;
    int outFd;
    int errFd;
    Runtime* rt;
    uv_timer_t* timer;
    ulong dataCb;
    ulong exitCb;
    bool reaped;
    int status;
    uint generation;
    char* wbuf;     // pending stdin bytes for a non-blocking child pipe
    size_t wlen;
    size_t woff;
    bool inEnd;     // end() was called; close the pipe once the queue drains
}

private Child[maxChildren] children;

// Ids are (generation << 8) | (index + 1). A released slot keeps its
// generation, so a ChildProcess handle that outlived its child can never read
// from, write to, or kill whichever child reuses the slot.
private int childId(uint index, uint generation) @nogc nothrow
{
    return cast(int) (((generation & 0x7F_FFFF) << 8) | (index + 1));
}

private Child* childLookup(int id) @nogc nothrow
{
    if (id < 1)
        return null;
    uint index = (cast(uint) id & 0xFF) - 1;
    uint generation = cast(uint) id >> 8;
    if (index >= maxChildren)
        return null;
    Child* c = &children[index];
    if (!c.used || c.generation != generation)
        return null;
    return c;
}

private void reapChild(pid_t pid) @nogc nothrow
{
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

private extern(C) void childTimerClose(uv_handle_t* h) nothrow @nogc { free(h); }

private void childClose(Child* c) @nogc nothrow
{
    if (c is null || !c.used) return;
    c.used = false;
    if (c.inFd >= 0) { close(c.inFd); c.inFd = -1; }
    if (c.outFd >= 0) { close(c.outFd); c.outFd = -1; }
    if (c.errFd >= 0) { close(c.errFd); c.errFd = -1; }
    free(c.wbuf);
    c.wbuf = null;
    c.wlen = c.woff = 0;
    if (c.timer !is null)
    {
        uv_timer_stop(c.timer);
        uv_close(cast(uv_handle_t*) c.timer, &childTimerClose);
        c.timer = null;
    }
    if (c.rt !is null)
    {
        if (c.dataCb != 0) registryRelease(c.rt.ctx, &c.rt.registry, c.dataCb);
        if (c.exitCb != 0) registryRelease(c.rt.ctx, &c.rt.registry, c.exitCb);
        c.dataCb = c.exitCb = 0;
    }
}

private enum size_t maxStdinBuffer = 16 * 1024 * 1024;

private void childFlushStdin(Child* c) @nogc nothrow
{
    if (c.inFd < 0 || c.wbuf is null)
        return;
    while (c.woff < c.wlen)
    {
        ssize_t n = write(c.inFd, c.wbuf + c.woff, c.wlen - c.woff);
        if (n > 0) { c.woff += cast(size_t) n; continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    if (c.woff >= c.wlen)
    {
        free(c.wbuf);
        c.wbuf = null;
        c.wlen = c.woff = 0;
        if (c.inEnd && c.inFd >= 0)
        {
            close(c.inFd);
            c.inFd = -1;
            c.inEnd = false;
        }
    }
}

private void childDrain(Child* c, int fd, int which) @nogc nothrow
{
    if (fd < 0) return;
    char[16384] tmp = void;
    while (true)
    {
        ssize_t n = read(fd, tmp.ptr, tmp.length);
        if (n > 0)
        {
            // Even without a data callback the pipe must be drained: leaving
            // it full blocks the child forever and keeps the slot alive.
            if (c.dataCb == 0 || c.rt is null)
                continue;
            CallbackSlot* slot = registryLookup(&c.rt.registry, c.dataCb);
            if (slot is null) return;
            JSValue chunk = JS_NewStringLen(c.rt.ctx, tmp.ptr, cast(size_t) n);
            JSValue fdVal = jsInt(which);
            JSValue[2] argv = [fdVal, chunk];
            JSValue fn = JS_DupValue(c.rt.ctx, slot.fn);
            JSValue r = JS_Call(c.rt.ctx, fn, jsUndefined(), 2, argv.ptr);
            JS_FreeValue(c.rt.ctx, fn);
            JS_FreeValue(c.rt.ctx, chunk);
            if (jsIsException(r))
            {
                JS_FreeValue(c.rt.ctx, r);
                runtimeReportUncaught(c.rt, c.rt.ctx);
                return;
            }
            JS_FreeValue(c.rt.ctx, r);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        return;
    }
}

private extern(C) void childTimerCb(uv_timer_t* timer) nothrow @nogc
{
    Child* c = cast(Child*) uv_handle_get_data(cast(uv_handle_t*) timer);
    if (c is null || !c.used) return;
    childFlushStdin(c);
    childDrain(c, c.outFd, 1);
    childDrain(c, c.errFd, 2);
    int status = 0;
    pid_t r = waitpid(c.pid, &status, 1); // WNOHANG
    if (r == c.pid)
    {
        c.reaped = true;
        c.status = status;
        // Final drain after exit.
        childDrain(c, c.outFd, 1);
        childDrain(c, c.errFd, 2);
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
        int sig = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
        if (c.exitCb != 0)
        {
            CallbackSlot* slot = registryLookup(&c.rt.registry, c.exitCb);
            if (slot !is null)
            {
                JSValue fn = JS_DupValue(c.rt.ctx, slot.fn);
                JSValue[2] argv = [jsInt(code), sig == 0 ? jsNull() : jsInt(sig)];
                JSValue res = JS_Call(c.rt.ctx, fn, jsUndefined(), 2, argv.ptr);
                JS_FreeValue(c.rt.ctx, fn);
                if (jsIsException(res)) { JS_FreeValue(c.rt.ctx, res); runtimeReportUncaught(c.rt, c.rt.ctx); }
                else JS_FreeValue(c.rt.ctx, res);
            }
        }
        childClose(c);
    }
}

private void freeAsyncArgs(JSContext* ctx, const(char)* fileJs, char** args,
                           int argCount, const(char)* cwd) @nogc nothrow
{
    if (cwd !is null) JS_FreeCString(ctx, cwd);
    if (fileJs !is null) JS_FreeCString(ctx, fileJs);
    if (args !is null)
    {
        for (int i = 1; i <= argCount; ++i)
            if (args[i] !is null) JS_FreeCString(ctx, args[i]);
        free(args);
    }
}

private char** readEnvArray(JSContext* ctx, JSValueConst options) @nogc nothrow
{
    JSValue ev = JS_GetPropertyStr(ctx, options, "_env");
    if (!JS_IsArray(ev)) { JS_FreeValue(ctx, ev); return null; }
    JSValue lenVal = JS_GetPropertyStr(ctx, ev, "length");
    int n = 0;
    if (!toInt32(ctx, lenVal, &n)) n = 0;
    JS_FreeValue(ctx, lenVal);
    if (n < 0) n = 0;
    char** envp = cast(char**) calloc(cast(size_t) n + 1, (char*).sizeof);
    if (envp is null) { JS_FreeValue(ctx, ev); return null; }
    for (int i = 0; i < n; ++i)
    {
        JSValue v = JS_GetPropertyUint32(ctx, ev, cast(uint) i);
        envp[i] = cast(char*) JS_ToCStringLen2(ctx, null, v, false);
        JS_FreeValue(ctx, v);
        if (envp[i] is null) break;
    }
    JS_FreeValue(ctx, ev);
    return envp;
}

private void freeEnvArray(JSContext* ctx, char** envp) @nogc nothrow
{
    if (envp is null) return;
    for (size_t i = 0; envp[i] !is null; ++i) JS_FreeCString(ctx, envp[i]);
    free(envp);
}

private extern(C) JSValue jsChildSpawnAsyncImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "spawn requires (file, args)");
    const(char)* fileJs = JS_ToCStringLen2(ctx, null, argv[0], false);
    if (fileJs is null) return jsException();
    int argCount = 0;
    JSValue lenVal = JS_GetPropertyStr(ctx, argv[1], "length");
    if (!toInt32(ctx, lenVal, &argCount)) argCount = 0;
    JS_FreeValue(ctx, lenVal);
    if (argCount < 0) argCount = 0;
    char** args = cast(char**) calloc(cast(size_t) argCount + 2, (char*).sizeof);
    if (args is null) { JS_FreeCString(ctx, fileJs); return throwInternalError(ctx, "out of memory"); }
    args[0] = cast(char*) fileJs;
    for (int i = 0; i < argCount; ++i)
    {
        JSValue v = JS_GetPropertyUint32(ctx, argv[1], cast(uint) i);
        args[i + 1] = cast(char*) JS_ToCStringLen2(ctx, null, v, false);
        JS_FreeValue(ctx, v);
        if (args[i + 1] is null)
        {
            freeAsyncArgs(ctx, fileJs, args, argCount, null);
            return jsException();
        }
    }
    const(char)* cwd = null;
    if (argc > 2 && jsIsObject(argv[2]))
    {
        JSValue cv = JS_GetPropertyStr(ctx, argv[2], "cwd");
        if (jsIsString(cv)) cwd = JS_ToCStringLen2(ctx, null, cv, false);
        JS_FreeValue(ctx, cv);
        if (cwd is null && JS_HasException(ctx))
        {
            freeAsyncArgs(ctx, fileJs, args, argCount, null);
            return jsException();
        }
    }
    if (cwd !is null && cwd[0] != 0 && !isDirectory(cwd))
    {
        JSValue e = makeError(ctx, "cwd is not a directory", "ENOENT", cwd, "chdir");
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwError(ctx, e);
    }
    if (!runAllowed(fileJs))
    {
        JSValue e = permissionThrow(ctx, Perm.run, fileJs);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return e;
    }
    char** envp = null;
    if (argc > 2 && jsIsObject(argv[2]))
    {
        JSValue evCheck = JS_GetPropertyStr(ctx, argv[2], "_env");
        if (jsIsException(evCheck))
        {
            JS_FreeValue(ctx, evCheck);
            freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
            return jsException();
        }
        JS_FreeValue(ctx, evCheck);
        envp = readEnvArray(ctx, argv[2]);
        if (envp is null && JS_HasException(ctx))
        {
            freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
            return jsException();
        }
    }

    // Reserve a slot before forking: a full table must not start a command it
    // is about to kill.
    int idx = -1;
    foreach (i; 0 .. maxChildren) if (!children[i].used) { idx = cast(int) i; break; }
    if (idx < 0)
    {
        freeEnvArray(ctx, envp);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "child table exhausted");
    }

    int[2] outp = void, errp = void, inp = void;
    if (pipe(outp) != 0)
    {
        freeEnvArray(ctx, envp);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&outp);
    if (pipe(errp) != 0)
    {
        close(outp[0]); close(outp[1]);
        freeEnvArray(ctx, envp);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&errp);
    if (pipe(inp) != 0)
    {
        close(outp[0]); close(outp[1]); close(errp[0]); close(errp[1]);
        freeEnvArray(ctx, envp);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "pipe failed");
    }
    makePipePair(&inp);

    pid_t pid = fork();
    if (pid < 0)
    {
        close(outp[0]); close(outp[1]); close(errp[0]); close(errp[1]); close(inp[0]); close(inp[1]);
        freeEnvArray(ctx, envp);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "fork failed");
    }
    if (pid == 0)
    {
        dup2(inp[0], 0); dup2(outp[1], 1); dup2(errp[1], 2);
        close(outp[0]); close(outp[1]); close(errp[0]); close(errp[1]); close(inp[0]); close(inp[1]);
        if (cwd !is null && cwd[0] != 0) chdir(cwd);
        execvpe(args[0], args, envp is null ? cast(char**) environ : envp);
        _exit(127);
    }
    close(outp[1]); close(errp[1]); close(inp[0]);
    freeEnvArray(ctx, envp);
    setNonBlocking(outp[0]);
    setNonBlocking(errp[0]);
    setNonBlocking(inp[1]);

    Child* c = &children[idx];
    uint generation = c.generation + 1;
    if (generation == 0) generation = 1;
    *c = Child.init;
    c.generation = generation;
    c.used = true;
    c.pid = pid;
    c.inFd = inp[1];
    c.outFd = outp[0];
    c.errFd = errp[0];
    c.rt = runtimeOf(ctx);
    c.timer = cast(uv_timer_t*) malloc(uv_handle_size(UV_TIMER));
    if (c.timer is null || uv_timer_init(c.rt.loop, c.timer) != 0)
    {
        kill(pid, SIGKILL);
        reapChild(pid);
        if (c.timer !is null) free(c.timer);
        c.timer = null;
        childClose(c);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "timer init failed");
    }
    uv_handle_set_data(cast(uv_handle_t*) c.timer, c);
    if (uv_timer_start(c.timer, &childTimerCb, 5, 5) != 0)
    {
        kill(pid, SIGKILL);
        reapChild(pid);
        uv_close(cast(uv_handle_t*) c.timer, &childTimerClose);
        c.timer = null;
        childClose(c);
        freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
        return throwInternalError(ctx, "timer start failed");
    }
    freeAsyncArgs(ctx, fileJs, args, argCount, cwd);
    return jsInt(childId(cast(uint) idx, c.generation));
}
extern(C) JSValue jsChildSpawnAsync(JSContext* ctx, JSValueConst thisVal, int argc,
                                    JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildSpawnAsyncImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChildOnDataImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "onData requires (id, callback)");
    Child* c = childLookup(id);
    if (c is null)
        return throwTypeError(ctx, "invalid child");
    if (c.dataCb != 0) registryRelease(c.rt.ctx, &c.rt.registry, c.dataCb);
    c.dataCb = registryAdd(ctx, &c.rt.registry, argv[1], null);
    return jsUndefined();
}
extern(C) JSValue jsChildOnData(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildOnDataImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChildOnExitImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "onExit requires (id, callback)");
    Child* c = childLookup(id);
    if (c is null)
        return throwTypeError(ctx, "invalid child");
    if (c.exitCb != 0) registryRelease(c.rt.ctx, &c.rt.registry, c.exitCb);
    c.exitCb = registryAdd(ctx, &c.rt.registry, argv[1], null);
    return jsUndefined();
}
extern(C) JSValue jsChildOnExit(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildOnExitImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChildWriteImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id) || !jsIsString(argv[1]))
        return throwTypeError(ctx, "write requires (id, string)");
    Child* c = childLookup(id);
    if (c is null || c.inFd < 0)
        return jsUndefined();
    if (c.inEnd)
        return jsInt(0);   // end() was called; the pipe is closing
    size_t len = 0;
    const(char)* data = JS_ToCStringLen2(ctx, &len, argv[1], false);
    if (data is null) return jsException();
    if (c.woff > 0)
    {
        if (c.woff >= c.wlen)
        {
            free(c.wbuf);
            c.wbuf = null;
            c.wlen = c.woff = 0;
        }
        else
        {
            memmove(c.wbuf, c.wbuf + c.woff, c.wlen - c.woff);
            c.wlen -= c.woff;
            c.woff = 0;
        }
    }
    if (len > maxStdinBuffer || c.wlen + len > maxStdinBuffer)
    {
        JS_FreeCString(ctx, data);
        return throwRangeError(ctx, "stdin buffer limit exceeded");
    }
    char* np = cast(char*) realloc(c.wbuf, c.wlen + len);
    if (np is null && len > 0)
    {
        JS_FreeCString(ctx, data);
        return throwInternalError(ctx, "out of memory");
    }
    c.wbuf = np;
    if (len > 0) memcpy(c.wbuf + c.wlen, data, len);
    c.wlen += len;
    JS_FreeCString(ctx, data);
    childFlushStdin(c);
    // The bytes are owned by the queue; report them as accepted. Delivery is
    // completed by the poll timer so a full pipe never blocks the loop.
    return jsInt(cast(int) len);
}
extern(C) JSValue jsChildWrite(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildWriteImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChildEndImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "end requires an id");
    Child* c = childLookup(id);
    if (c is null) return jsUndefined();
    c.inEnd = true;
    childFlushStdin(c);
    if (c.wbuf is null && c.inFd >= 0)
    {
        close(c.inFd);
        c.inFd = -1;
        c.inEnd = false;
    }
    return jsUndefined();
}
extern(C) JSValue jsChildEnd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildEndImpl(ctx, thisVal, argc, argv); }

private int signalFromName(const(char)* name) @nogc nothrow
{
    if (strcmp(name, "SIGTERM") == 0) return SIGTERM;
    if (strcmp(name, "SIGKILL") == 0) return SIGKILL;
    if (strcmp(name, "SIGINT") == 0) return 2;
    if (strcmp(name, "SIGHUP") == 0) return 1;
    if (strcmp(name, "SIGQUIT") == 0) return 3;
    return -1;
}

private extern(C) JSValue jsChildKillImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "kill requires an id");
    Child* c = childLookup(id);
    if (c is null) return jsUndefined();
    int sig = SIGTERM;
    if (argc > 1 && !jsIsUndefined(argv[1]))
    {
        if (jsIsString(argv[1]))
        {
            const(char)* name = JS_ToCStringLen2(ctx, null, argv[1], false);
            if (name is null) return jsException();
            sig = signalFromName(name);
            JS_FreeCString(ctx, name);
            if (sig < 0)
                return throwRangeError(ctx, "unknown signal");
        }
        else if (!toInt32(ctx, argv[1], &sig))
            return jsException();
        if (sig < 0 || sig > 64)
            return throwRangeError(ctx, "invalid signal");
    }
    kill(c.pid, sig);
    return jsUndefined();
}
extern(C) JSValue jsChildKill(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildKillImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsChildPidImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return jsNull();
    Child* c = childLookup(id);
    if (c is null) return jsNull();
    return jsInt(cast(int) c.pid);
}
extern(C) JSValue jsChildPid(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsChildPidImpl(ctx, thisVal, argc, argv); }

bool installChild(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "spawnSync", &jsChildSpawnSync, 3)
        && addNativeFunction(ctx, obj, "spawn", &jsChildSpawnAsync, 3)
        && addNativeFunction(ctx, obj, "onData", &jsChildOnData, 2)
        && addNativeFunction(ctx, obj, "onExit", &jsChildOnExit, 2)
        && addNativeFunction(ctx, obj, "write", &jsChildWrite, 2)
        && addNativeFunction(ctx, obj, "end", &jsChildEnd, 1)
        && addNativeFunction(ctx, obj, "kill", &jsChildKill, 2)
        && addNativeFunction(ctx, obj, "pid", &jsChildPid, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "child", obj) < 0) { JS_FreeValue(ctx, obj); return false; }
    return true;
}
