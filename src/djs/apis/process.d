module djs.apis.process;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strlen;
import core.stdc.errno : EPERM, ESRCH, errno;
import core.sys.posix.signal : SIGHUP, SIGINT, SIGQUIT, SIGKILL, SIGTERM, SIGUSR1, SIGUSR2,
    SIGPIPE, SIGALRM, SIGCHLD, SIGCONT, SIGSTOP, kill;
import core.sys.posix.time : timespec;
import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
import core.sys.posix.sys.stat : umask;
import core.sys.posix.unistd : getcwd, getpid, getppid;

import djs.platform : CLOCK_MONOTONIC, Mode, clock_gettime, environPtr, peakRssBytes;

import djs.loop.libuv : uv_version_string;
import djs.bindings.quickjs;
import djs.bindings.value;
import djs.permissions : Perm, permissionHas, permissionCheck, permissionFromName, permissionThrow, permissionsRevoke;
import djs.runtime : Runtime, djsVersion, guarded, runtimeOf, runtimeRequestExit;

extern(C) int uv_exepath(char* buffer, size_t* size) nothrow @nogc;

private extern(C) JSValue jsProcessPpid(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    return jsInt(cast(int) getppid());
}

private extern(C) JSValue jsProcessPid(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    return jsInt(cast(int) getpid());
}

private extern(C) JSValue jsProcessExecPath(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    char[4096] buf;
    size_t n = buf.length;
    if (uv_exepath(buf.ptr, &n) < 0)
        return newString(ctx, "");
    buf[n < buf.length ? n : buf.length - 1] = 0;
    return newString(ctx, buf.ptr);
}

private JSValue processArgv(Runtime* self) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue arr = JS_NewArray(ctx);
    if (jsIsException(arr))
        return arr;
    for (int i = 0; i < self.argc; ++i)
    {
        JSValue s = newString(ctx, self.argv[i]);
        if (jsIsException(s))
        {
            JS_FreeValue(ctx, arr);
            return s;
        }
        if (!setIndex(ctx, arr, cast(uint) i, s))
        {
            JS_FreeValue(ctx, arr);
            return jsException();
        }
    }
    return arr;
}

// Keys are passed to QuickJS with their real length; no fixed-size buffer.
private JSValue processEnv(JSContext* ctx) @nogc nothrow
{
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return obj;
    char** env = environPtr();
    if (env is null)
        return obj;
    for (size_t i = 0; env[i] !is null; ++i)
    {
        const(char)* entry = env[i];
        size_t eq = 0;
        while (entry[eq] != 0 && entry[eq] != '=')
            eq += 1;
        if (entry[eq] != '=')
            continue;
        JSValue val = JS_NewStringLen(ctx, entry + eq + 1, strlen(entry + eq + 1));
        if (jsIsException(val))
        {
            JS_FreeValue(ctx, obj);
            return val;
        }
        // setProp consumes val. JS_SetPropertyStr needs a NUL-terminated key,
        // and the environment entry is not one at the '='.
        char* keyz = cast(char*) malloc(eq + 1);
        if (keyz is null)
        {
            JS_FreeValue(ctx, val);
            JS_FreeValue(ctx, obj);
            throwInternalError(ctx, "out of memory");
            return jsException();
        }
        memcpy(keyz, entry, eq);
        keyz[eq] = 0;
        // The startup snapshot filters with a side-effect-free query: no
        // prompts before user code runs, no audit noise, no cached grants.
        if (!permissionHas(Perm.env, keyz))
        {
            JS_FreeValue(ctx, val);
            free(keyz);
            continue;
        }
        bool ok = JS_SetPropertyStr(ctx, obj, keyz, val) > 0;
        free(keyz);
        if (!ok)
        {
            JS_FreeValue(ctx, obj);
            return jsException();
        }
    }
    return obj;
}

private JSValue processCwd(JSContext* ctx) @nogc nothrow
{
    char[4096] buf = void;
    if (getcwd(buf.ptr, buf.length) is null)
        return throwInternalError(ctx, "getcwd failed");
    return JS_NewStringLen(ctx, buf.ptr, strlen(buf.ptr));
}

private long readRss() @nogc nothrow
{
    version (linux)
    {
        import core.sys.posix.fcntl : O_RDONLY, open;
        import core.sys.posix.unistd : close, read;
        int fd = open("/proc/self/statm", O_RDONLY);
        if (fd < 0)
            return 0;
        char[128] buf = void;
        ptrdiff_t n = read(fd, buf.ptr, buf.length - 1);
        close(fd);
        if (n <= 0)
            return 0;
        buf[n] = 0;
        // The second field is resident pages.
        size_t i = 0;
        while (i < cast(size_t) n && buf[i] != ' ')
            i += 1;
        while (i < cast(size_t) n && buf[i] == ' ')
            i += 1;
        long pages = 0;
        while (i < cast(size_t) n && buf[i] >= '0' && buf[i] <= '9')
        {
            pages = pages * 10 + (buf[i] - '0');
            i += 1;
        }
        return pages * 4096;
    }
    else version (OSX)
    {
        // Darwin reports peak RSS in bytes; Node reports current RSS, so this
        // is an over-estimate on a long-lived process. Better than zero.
        return peakRssBytes();
    }
    else
    {
        return 0;
    }
}

private JSValue processMemoryUsage(JSContext* ctx, Runtime* self) @nogc nothrow
{
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return obj;
    JSMemoryUsage mu = void;
    JS_ComputeMemoryUsage(self.rt, &mu);
    setProp(ctx, obj, "rss", jsFloat(cast(double) readRss()));
    setProp(ctx, obj, "heapTotal", jsFloat(cast(double) mu.malloc_size));
    setProp(ctx, obj, "heapUsed", jsFloat(cast(double) mu.memory_used_size));
    // QuickJS is patched to account live ArrayBuffer bytes exactly; the
    // engine's binary_object_size only counts deserialized bytecode.
    double arrays = cast(double) JS_GetArrayBufferBytes(ctx);
    setProp(ctx, obj, "external", jsFloat(arrays));
    setProp(ctx, obj, "arrayBuffers", jsFloat(arrays));
    return obj;
}

// Full QuickJS accounting for the v8 shim: process.memoryUsage() only needs
// five numbers, but getHeapStatistics() and getHeapCodeStatistics() expose
// object counts and code size, and those must come from the engine rather than
// be invented in JS.
private JSValue processMemoryStats(JSContext* ctx, Runtime* self) @nogc nothrow
{
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return obj;
    JSMemoryUsage mu = void;
    JS_ComputeMemoryUsage(self.rt, &mu);
    setProp(ctx, obj, "mallocSize", jsFloat(cast(double) mu.malloc_size));
    setProp(ctx, obj, "mallocLimit", jsFloat(cast(double) mu.malloc_limit));
    setProp(ctx, obj, "memoryLimit", jsFloat(cast(double) self.memoryLimit));
    setProp(ctx, obj, "memoryUsedSize", jsFloat(cast(double) mu.memory_used_size));
    setProp(ctx, obj, "mallocCount", jsFloat(cast(double) mu.malloc_count));
    setProp(ctx, obj, "atomCount", jsFloat(cast(double) mu.atom_count));
    setProp(ctx, obj, "atomSize", jsFloat(cast(double) mu.atom_size));
    setProp(ctx, obj, "strCount", jsFloat(cast(double) mu.str_count));
    setProp(ctx, obj, "strSize", jsFloat(cast(double) mu.str_size));
    setProp(ctx, obj, "objCount", jsFloat(cast(double) mu.obj_count));
    setProp(ctx, obj, "objSize", jsFloat(cast(double) mu.obj_size));
    setProp(ctx, obj, "propCount", jsFloat(cast(double) mu.prop_count));
    setProp(ctx, obj, "propSize", jsFloat(cast(double) mu.prop_size));
    setProp(ctx, obj, "shapeCount", jsFloat(cast(double) mu.shape_count));
    setProp(ctx, obj, "shapeSize", jsFloat(cast(double) mu.shape_size));
    setProp(ctx, obj, "jsFuncCount", jsFloat(cast(double) mu.js_func_count));
    setProp(ctx, obj, "jsFuncSize", jsFloat(cast(double) mu.js_func_size));
    setProp(ctx, obj, "jsFuncCodeSize", jsFloat(cast(double) mu.js_func_code_size));
    setProp(ctx, obj, "fastArrayCount", jsFloat(cast(double) mu.fast_array_count));
    setProp(ctx, obj, "fastArrayElements", jsFloat(cast(double) mu.fast_array_elements));
    setProp(ctx, obj, "binaryObjectCount", jsFloat(cast(double) mu.binary_object_count));
    setProp(ctx, obj, "binaryObjectSize", jsFloat(cast(double) mu.binary_object_size));
    setProp(ctx, obj, "arrayBufferBytes", jsFloat(cast(double) JS_GetArrayBufferBytes(ctx)));
    return obj;
}

private extern(C) JSValue jsProcessArgvImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return JS_NewArray(ctx);
    return processArgv(self);
}

extern(C) JSValue jsProcessArgv(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessArgvImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessEnvImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    return processEnv(ctx);
}

extern(C) JSValue jsProcessEnv(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessEnvImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessCwdImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    return processCwd(ctx);
}

extern(C) JSValue jsProcessCwd(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessCwdImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessExitImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    int code = 0;
    if (argc >= 1)
    {
        if (!toInt32(ctx, argv[0], &code))
            return jsException();
    }
    if (self !is null)
        runtimeRequestExit(self, code);
    // This is a request, not an immediate exit: JS continues to the end of
    // the current turn, and teardown runs only after the loop returns.
    return jsUndefined();
}

extern(C) JSValue jsProcessExit(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessExitImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessPlatformImpl(JSContext* ctx, JSValueConst, int,
                                                JSValueConst*) nothrow @nogc
{
    version (linux)
        return newString(ctx, "linux");
    else version (OSX)
        return newString(ctx, "darwin");
    else version (FreeBSD)
        return newString(ctx, "freebsd");
    else
        return newString(ctx, "unknown");
}

extern(C) JSValue jsProcessPlatform(JSContext* ctx, JSValueConst thisVal, int argc,
                                    JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessPlatformImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessArchImpl(JSContext* ctx, JSValueConst, int,
                                             JSValueConst*) nothrow @nogc
{
    version (X86_64)
        return newString(ctx, "x64");
    else version (AArch64)
        return newString(ctx, "arm64");
    else version (Arm)
        return newString(ctx, "arm");
    else
        return newString(ctx, "unknown");
}

extern(C) JSValue jsProcessArch(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessArchImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessVersionImpl(JSContext* ctx, JSValueConst, int,
                                               JSValueConst*) nothrow @nogc
{
    return newString(ctx, djsVersion);
}

extern(C) JSValue jsProcessVersion(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessVersionImpl(ctx, thisVal, argc, argv);
}

// util.types.isProxy needs an engine-level predicate: proxies are transparent
// to every JS-level test in QuickJS.
private extern(C) JSValue jsProcessIsProxyImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    return jsBool(argc > 0 && JS_IsProxy(argv[0]));
}

extern(C) JSValue jsProcessIsProxy(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessIsProxyImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessUvVersionImpl(JSContext* ctx, JSValueConst, int,
                                                 JSValueConst*) nothrow @nogc
{
    return newString(ctx, uv_version_string());
}

extern(C) JSValue jsProcessUvVersion(JSContext* ctx, JSValueConst thisVal, int argc,
                                     JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessUvVersionImpl(ctx, thisVal, argc, argv);
}

// process.exitCode: the status the loop reports when it drains on its own.
private extern(C) JSValue jsProcessSetExitCodeImpl(JSContext* ctx, JSValueConst, int argc,
                                                   JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return jsUndefined();
    int code = 0;
    if (argc > 0 && JS_ToInt32(ctx, &code, argv[0]) < 0)
        return jsException();
    self.exitCode = code;
    return jsUndefined();
}

extern(C) JSValue jsProcessSetExitCode(JSContext* ctx, JSValueConst thisVal, int argc,
                                       JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessSetExitCodeImpl(ctx, thisVal, argc, argv);
}


private double monotonicSeconds() @nogc nothrow
{
    timespec ts = void;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return cast(double) ts.tv_sec + cast(double) ts.tv_nsec / 1_000_000_000.0;
}

private __gshared double processStartSeconds;

private extern(C) JSValue jsProcessHrtimeImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    timespec ts = void;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return throwInternalError(ctx, "clock_gettime failed");
    JSValue arr = JS_NewArray(ctx);
    if (jsIsException(arr)) return arr;
    setIndex(ctx, arr, 0, jsInt(cast(int) ts.tv_sec));
    setIndex(ctx, arr, 1, jsInt(cast(int) ts.tv_nsec));
    return arr;
}
extern(C) JSValue jsProcessHrtime(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsProcessHrtimeImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsProcessUptimeImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    double now = monotonicSeconds();
    double start = processStartSeconds;
    return jsFloat(now > start ? now - start : 0);
}
extern(C) JSValue jsProcessUptime(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsProcessUptimeImpl(ctx, thisVal, argc, argv); }

private int signalNumber(const(char)* name, size_t len, bool* ok) @nogc nothrow
{
    *ok = true;
    if (len > 0 && name[0] >= '0' && name[0] <= '9')
    {
        int n = 0;
        for (size_t i = 0; i < len; ++i)
        {
            if (name[i] < '0' || name[i] > '9') { *ok = false; return 0; }
            n = n * 10 + (name[i] - '0');
        }
        return n;
    }
    struct Sig { const(char)* name; int num; }
    static immutable Sig[] table = [
        Sig("SIGHUP", SIGHUP), Sig("SIGINT", SIGINT), Sig("SIGQUIT", SIGQUIT),
        Sig("SIGKILL", SIGKILL), Sig("SIGTERM", SIGTERM), Sig("SIGUSR1", SIGUSR1),
        Sig("SIGUSR2", SIGUSR2), Sig("SIGPIPE", SIGPIPE), Sig("SIGALRM", SIGALRM),
        Sig("SIGCHLD", SIGCHLD), Sig("SIGCONT", SIGCONT), Sig("SIGSTOP", SIGSTOP),
    ];
    foreach (ref e; table)
    {
        size_t i = 0;
        while (i < len && e.name[i] != 0 && e.name[i] == name[i]) i += 1;
        if (i == len && e.name[i] == 0) return e.num;
    }
    *ok = false;
    return 0;
}

private extern(C) JSValue jsProcessKillImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int pid = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &pid))
        return throwTypeError(ctx, "process.kill requires a pid");
    int sig = SIGTERM;
    if (argc >= 2 && !jsIsUndefined(argv[1]))
    {
        if (jsIsNumber(argv[1]))
        {
            if (!toInt32(ctx, argv[1], &sig)) return throwTypeError(ctx, "invalid signal");
        }
        else if (jsIsString(argv[1]))
        {
            const(char)* name = null;
            size_t len = 0;
            if (!toStringView(ctx, argv[1], &name, &len)) return jsException();
            bool ok = false;
            sig = signalNumber(name, len, &ok);
            JS_FreeCString(ctx, name);
            if (!ok) return throwTypeError(ctx, "unknown signal name");
        }
        else return throwTypeError(ctx, "invalid signal");
    }
    if (!permissionCheck(Perm.sys, "kill"))
        return permissionThrow(ctx, Perm.sys, "kill");
    if (kill(pid, sig) == 0) return jsBool(true);
    int e = errno;
    if (e == EPERM) return jsBool(true);
    // The error has to be thrown: returning it handed callers an Error object
    // as the call's value instead of an exception (Node throws ESRCH).
    if (e == ESRCH)
        return throwError(ctx, makeError(ctx, "no such process", "ESRCH", null, "kill"));
    return throwError(ctx, makeError(ctx, "kill failed", "EINVAL", null, "kill"));
}
extern(C) JSValue jsProcessKill(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsProcessKillImpl(ctx, thisVal, argc, argv); }


private extern(C) JSValue jsProcessCpuUsageImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    rusage ru = void;
    if (getrusage(RUSAGE_SELF, &ru) != 0)
        return throwInternalError(ctx, "getrusage failed");
    JSValue o = JS_NewObject(ctx);
    if (jsIsException(o)) return o;
    long user = cast(long) ru.ru_utime.tv_sec * 1_000_000 + ru.ru_utime.tv_usec;
    long sys = cast(long) ru.ru_stime.tv_sec * 1_000_000 + ru.ru_stime.tv_usec;
    JS_SetPropertyStr(ctx, o, "user", jsFloat(cast(double) user));
    JS_SetPropertyStr(ctx, o, "system", jsFloat(cast(double) sys));
    return o;
}
extern(C) JSValue jsProcessCpuUsage(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsProcessCpuUsageImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsProcessUmaskImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc >= 1 && !jsIsUndefined(argv[0]))
    {
        int mask = 0;
        if (!toInt32(ctx, argv[0], &mask)) return throwTypeError(ctx, "umask requires a number");
        int old = umask(cast(Mode) mask);
        return jsInt(old);
    }
    int old = umask(0);
    umask(cast(Mode) old);
    return jsInt(old);
}
extern(C) JSValue jsProcessUmask(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsProcessUmaskImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsProcessMemoryImpl(JSContext* ctx, JSValueConst, int,
                                              JSValueConst*) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    return processMemoryUsage(ctx, self);
}

extern(C) JSValue jsProcessMemory(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessMemoryImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsProcessMemoryStatsImpl(JSContext* ctx, JSValueConst,
                                                   int, JSValueConst*) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    return processMemoryStats(ctx, self);
}

extern(C) JSValue jsProcessMemoryStats(JSContext* ctx, JSValueConst thisVal,
                                       int argc, JSValueConst* argv) nothrow @nogc
{
    return guarded!jsProcessMemoryStatsImpl(ctx, thisVal, argc, argv);
}

private bool memcmpZ(const(char)* a, const(char)* b, size_t n) @nogc nothrow
{
    for (size_t i = 0; i < n; ++i)
        if (a[i] != b[i])
            return false;
    return true;
}

private Perm scopeToPerm(const(char)* scopeName, size_t len) @nogc nothrow
{
    if (len == 7 && memcmpZ(scopeName, "fs.read", 7)) return Perm.read;
    if (len == 8 && memcmpZ(scopeName, "fs.write", 8)) return Perm.write;
    return permissionFromName(scopeName, len);
}

private extern(C) JSValue jsPermissionHasImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "permission.has requires a scope");
    size_t sl = 0;
    const(char)* scopeName = JS_ToCStringLen2(ctx, &sl, argv[0], false);
    if (scopeName is null)
        return jsException();
    Perm p = scopeToPerm(scopeName, sl);
    const(char)* resource = null;
    size_t rl = 0;
    if (argc >= 2)
        resource = JS_ToCStringLen2(ctx, &rl, argv[1], false);
    // Query the rules without prompting, auditing, or granting: has() must
    // be side-effect-free (Node/Deno semantics).
    bool allowed = p != cast(Perm) 0 && permissionHas(p, resource);
    if (resource !is null)
        JS_FreeCString(ctx, resource);
    JS_FreeCString(ctx, scopeName);
    return jsBool(allowed);
}

private extern(C) JSValue jsPermissionHas(JSContext* ctx, JSValueConst thisVal, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    return guarded!jsPermissionHasImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsPermissionDropImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "permission.drop requires a scope");
    size_t sl = 0;
    const(char)* scopeName = JS_ToCStringLen2(ctx, &sl, argv[0], false);
    if (scopeName is null)
        return jsException();
    Perm p = scopeToPerm(scopeName, sl);
    JS_FreeCString(ctx, scopeName);
    if (p == cast(Perm) 0)
        return jsBool(false);
    permissionsRevoke(p);
    return jsBool(true);
}

private extern(C) JSValue jsPermissionDrop(JSContext* ctx, JSValueConst thisVal, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    return guarded!jsPermissionDropImpl(ctx, thisVal, argc, argv);
}

bool installProcess(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    processStartSeconds = monotonicSeconds();
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "argv", &jsProcessArgv, 0)
        && addNativeFunction(ctx, obj, "env", &jsProcessEnv, 0)
        && addNativeFunction(ctx, obj, "cwd", &jsProcessCwd, 0)
        && addNativeFunction(ctx, obj, "exit", &jsProcessExit, 1)
        && addNativeFunction(ctx, obj, "platform", &jsProcessPlatform, 0)
        && addNativeFunction(ctx, obj, "arch", &jsProcessArch, 0)
        && addNativeFunction(ctx, obj, "execPath", &jsProcessExecPath, 0)
        && addNativeFunction(ctx, obj, "pid", &jsProcessPid, 0)
        && addNativeFunction(ctx, obj, "ppid", &jsProcessPpid, 0)
        && addNativeFunction(ctx, obj, "version", &jsProcessVersion, 0)
        && addNativeFunction(ctx, obj, "memoryUsage", &jsProcessMemory, 0)
        && addNativeFunction(ctx, obj, "memoryStats", &jsProcessMemoryStats, 0)
        && addNativeFunction(ctx, obj, "hrtime", &jsProcessHrtime, 0)
        && addNativeFunction(ctx, obj, "uptime", &jsProcessUptime, 0)
        && addNativeFunction(ctx, obj, "kill", &jsProcessKill, 2)
        && addNativeFunction(ctx, obj, "cpuUsage", &jsProcessCpuUsage, 0)
        && addNativeFunction(ctx, obj, "umask", &jsProcessUmask, 1)
        && addNativeFunction(ctx, obj, "isProxy", &jsProcessIsProxy, 1)
        && addNativeFunction(ctx, obj, "uvVersion", &jsProcessUvVersion, 0)
        && addNativeFunction(ctx, obj, "setExitCode", &jsProcessSetExitCode, 1);
    if (ok)
    {
        JSValue perm = JS_NewObject(ctx);
        if (jsIsException(perm))
            ok = false;
        else
        {
            ok = addNativeFunction(ctx, perm, "has", &jsPermissionHas, 2)
                && addNativeFunction(ctx, perm, "drop", &jsPermissionDrop, 1)
                && JS_SetPropertyStr(ctx, obj, "permission", perm) > 0;
            if (!ok)
                JS_FreeValue(ctx, perm);
        }
    }
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "process", obj) > 0;
}
