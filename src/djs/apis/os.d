module djs.apis.os;

import core.stdc.stdlib : getenv, malloc, free;
import core.stdc.string : memcpy, strlen;
import core.sys.posix.unistd : gethostname, getuid, sysconf;
import core.sys.posix.pwd : passwd, getpwuid_r;
import core.sys.posix.time : clock_gettime, timespec;
import core.sys.posix.arpa.inet : inet_ntop;
import core.sys.posix.netinet.in_ : AF_INET, AF_INET6, sockaddr_in, sockaddr_in6;
import core.sys.posix.sys.socket : sockaddr;

// glibc sysconf names (Linux). D's posix bindings do not expose these.
private enum int SC_PAGESIZE = 30;
private enum int SC_PHYS_PAGES = 85;
private enum int SC_AVPHYS_PAGES = 86;
private enum int SC_NPROCESSORS_ONLN = 84;
import core.sys.posix.sys.utsname : uname, utsname;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.permissions : Perm, permissionHas, permissionCheck, permissionThrow;
import djs.runtime : Runtime, guarded;

private long sysconfLong(int name) @nogc nothrow
{
    long v = sysconf(name);
    return v > 0 ? v : 0;
}

private extern(C) JSValue jsOsCpusImpl(JSContext* ctx, JSValueConst, int,
                                       JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "cpus"))
        return permissionThrow(ctx, Perm.sys, "cpus");
    long n = sysconfLong(SC_NPROCESSORS_ONLN);
    if (n <= 0) n = 1;
    if (n > 1024) n = 1024;
    JSValue arr = JS_NewArray(ctx);
    if (jsIsException(arr))
        return arr;
    for (long i = 0; i < n; ++i)
    {
        JSValue cpu = JS_NewObject(ctx);
        if (jsIsException(cpu))
        {
            JS_FreeValue(ctx, arr);
            return cpu;
        }
        setProp(ctx, cpu, "model", newString(ctx, "unknown"));
        setProp(ctx, cpu, "speed", jsInt(0));
        if (!setIndex(ctx, arr, cast(uint) i, cpu))
        {
            JS_FreeValue(ctx, arr);
            return jsException();
        }
    }
    return arr;
}

private extern(C) JSValue jsOsCpus(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsCpusImpl(ctx, thisVal, argc, argv);
}

private double totalMemory() @nogc nothrow
{
    double pages = cast(double) sysconfLong(SC_PHYS_PAGES);
    double size = cast(double) sysconfLong(SC_PAGESIZE);
    return pages * size;
}

private extern(C) JSValue jsOsTotalmemImpl(JSContext* ctx, JSValueConst, int,
                                           JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "systemMemoryInfo"))
        return permissionThrow(ctx, Perm.sys, "systemMemoryInfo");
    return jsFloat(totalMemory());
}

private extern(C) JSValue jsOsTotalmem(JSContext* ctx, JSValueConst thisVal, int argc,
                                       JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsTotalmemImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsOsFreememImpl(JSContext* ctx, JSValueConst, int,
                                          JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "systemMemoryInfo"))
        return permissionThrow(ctx, Perm.sys, "systemMemoryInfo");
    return jsFloat(cast(double) sysconfLong(SC_AVPHYS_PAGES) *
                   cast(double) sysconfLong(SC_PAGESIZE));
}

private extern(C) JSValue jsOsFreemem(JSContext* ctx, JSValueConst thisVal, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsFreememImpl(ctx, thisVal, argc, argv);
}

private char* hostNameAlloc() @nogc nothrow
{
    char[256] buf = void;
    if (gethostname(buf.ptr, buf.length) != 0)
        return null;
    buf[buf.length - 1] = 0;
    size_t n = strlen(buf.ptr);
    char* p = cast(char*) malloc(n + 1);
    if (p is null)
        return null;
    memcpy(p, buf.ptr, n + 1);
    return p;
}

private char* releaseAlloc() @nogc nothrow
{
    utsname u = void;
    if (uname(&u) != 0)
        return null;
    const(char)* r = (&u.release[0]);
    size_t n = strlen(r);
    char* p = cast(char*) malloc(n + 1);
    if (p is null)
        return null;
    memcpy(p, r, n + 1);
    return p;
}

private const(char)* envOr(const(char)* name, const(char)* fallback) @nogc nothrow
{
    const(char)* v = getenv(name);
    return v is null ? fallback : v;
}


private extern(C) JSValue jsOsHostnameImpl(JSContext* ctx, JSValueConst, int,
                                           JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "hostname"))
        return permissionThrow(ctx, Perm.sys, "hostname");
    char* host = hostNameAlloc();
    if (host is null)
        return newString(ctx, "");
    JSValue v = newString(ctx, host);
    free(host);
    return v;
}

private extern(C) JSValue jsOsHostname(JSContext* ctx, JSValueConst thisVal, int argc,
                                       JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsHostnameImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsOsReleaseImpl(JSContext* ctx, JSValueConst, int,
                                          JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "osRelease"))
        return permissionThrow(ctx, Perm.sys, "osRelease");
    char* rel = releaseAlloc();
    if (rel is null)
        return newString(ctx, "");
    JSValue v = newString(ctx, rel);
    free(rel);
    return v;
}

private extern(C) JSValue jsOsRelease(JSContext* ctx, JSValueConst thisVal, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsReleaseImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsOsTmpdirImpl(JSContext* ctx, JSValueConst, int,
                                         JSValueConst*) nothrow @nogc
{
    // Denied TMPDIR falls back to /tmp instead of throwing: os.tmpdir() is
    // on every defensive library's startup path.
    if (!permissionHas(Perm.env, "TMPDIR"))
        return newString(ctx, "/tmp");
    return newString(ctx, envOr("TMPDIR", "/tmp"));
}

private extern(C) JSValue jsOsTmpdir(JSContext* ctx, JSValueConst thisVal, int argc,
                                     JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsTmpdirImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsOsHomedirImpl(JSContext* ctx, JSValueConst, int,
                                          JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.env, "HOME"))
        return permissionThrow(ctx, Perm.env, "HOME");
    return newString(ctx, envOr("HOME", ""));
}

private extern(C) JSValue jsOsHomedir(JSContext* ctx, JSValueConst thisVal, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    return guarded!jsOsHomedirImpl(ctx, thisVal, argc, argv);
}


private enum int CLOCK_BOOTTIME = 7;

private struct ifaddrs
{
    ifaddrs* ifa_next;
    char* ifa_name;
    uint ifa_flags;
    sockaddr* ifa_addr;
    sockaddr* ifa_netmask;
    void* ifa_ifu;
    void* ifa_data;
}

extern(C) int getifaddrs(ifaddrs** ifap) nothrow @nogc;
extern(C) void freeifaddrs(ifaddrs* ifa) nothrow @nogc;
extern(C) int getloadavg(double* loadavg, int nelem) nothrow @nogc;

private enum uint IFF_UP = 0x1;
private enum uint IFF_LOOPBACK = 0x8;

private extern(C) JSValue jsOsUptimeImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "uptime"))
        return permissionThrow(ctx, Perm.sys, "uptime");
    timespec ts = void;
    if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0)
        return jsFloat(0);
    return jsFloat(cast(double) ts.tv_sec + cast(double) ts.tv_nsec / 1_000_000_000.0);
}
extern(C) JSValue jsOsUptime(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsOsUptimeImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsOsLoadavgImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "loadavg"))
        return permissionThrow(ctx, Perm.sys, "loadavg");
    double[3] v = void;
    int n = getloadavg(v.ptr, 3);
    JSValue arr = JS_NewArray(ctx);
    if (jsIsException(arr)) return arr;
    for (int i = 0; i < 3; ++i)
        setIndex(ctx, arr, cast(uint) i, jsFloat(i < n ? v[i] : 0));
    return arr;
}
extern(C) JSValue jsOsLoadavg(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsOsLoadavgImpl(ctx, thisVal, argc, argv); }

private int maskBits(const(ubyte)* p, int bytes) @nogc nothrow
{
    int bits = 0;
    foreach (i; 0 .. bytes)
    {
        ubyte b = p[i];
        while (b != 0) { bits += b & 1; b >>= 1; }
        if (b == 0 && p[i] != 0xFF) break;
    }
    return bits;
}

private void addInterface(JSContext* ctx, JSValue root, const(char)* name, int family,
                          const(ubyte)* addr, const(ubyte)* mask, int bytes, uint flags) @nogc nothrow
{
    char[64] text = void;
    if (inet_ntop(family, addr, text.ptr, text.length) is null) return;
    char[64] maskText = void;
    const(char)* mt = inet_ntop(family, mask, maskText.ptr, maskText.length);
    if (mt is null) return;
    int bits = maskBits(mask, bytes);
    JSValue entry = JS_NewObject(ctx);
    if (jsIsException(entry)) return;
    char[160] cidr = void;
    import core.stdc.stdio : snprintf;
    snprintf(cidr.ptr, cidr.length, "%s/%d", text.ptr, bits);
    JSValue familyName = newString(ctx, family == AF_INET ? "IPv4" : "IPv6");
    JS_SetPropertyStr(ctx, entry, "address", newString(ctx, text.ptr));
    JS_SetPropertyStr(ctx, entry, "netmask", newString(ctx, mt));
    JS_SetPropertyStr(ctx, entry, "family", familyName);
    JS_SetPropertyStr(ctx, entry, "mac", newString(ctx, "00:00:00:00:00:00"));
    JS_SetPropertyStr(ctx, entry, "internal", jsBool((flags & IFF_LOOPBACK) != 0));
    JS_SetPropertyStr(ctx, entry, "cidr", newString(ctx, cidr.ptr));

    JSValue existing = JS_GetPropertyStr(ctx, root, name);
    if (jsIsUndefined(existing))
    {
        JS_FreeValue(ctx, existing);
        JSValue arr = JS_NewArray(ctx);
        setIndex(ctx, arr, 0, entry);
        JS_SetPropertyStr(ctx, root, name, arr);
    }
    else
    {
        int len = 0;
        JSValue lenv = JS_GetPropertyStr(ctx, existing, "length");
        toInt32(ctx, lenv, &len);
        JS_FreeValue(ctx, lenv);
        setIndex(ctx, existing, cast(uint) (len > 0 ? len : 0), entry);
        JS_FreeValue(ctx, existing);
    }
}

private extern(C) JSValue jsOsNetworkInterfacesImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "networkInterfaces"))
        return permissionThrow(ctx, Perm.sys, "networkInterfaces");
    ifaddrs* list = null;
    if (getifaddrs(&list) != 0)
        return throwInternalError(ctx, "getifaddrs failed");
    JSValue root = JS_NewObject(ctx);
    if (jsIsException(root)) { freeifaddrs(list); return root; }
    for (ifaddrs* it = list; it !is null; it = it.ifa_next)
    {
        if (it.ifa_addr is null || it.ifa_name is null) continue;
        int family = it.ifa_addr.sa_family;
        if (family == AF_INET)
        {
            sockaddr_in* sa = cast(sockaddr_in*) it.ifa_addr;
            sockaddr_in* nm = cast(sockaddr_in*) it.ifa_netmask;
            ubyte[4] mask = [0, 0, 0, 0];
            if (nm !is null)
            {
                auto raw = cast(const(ubyte)*) &nm.sin_addr.s_addr;
                foreach (i; 0 .. 4) mask[i] = raw[i];
            }
            addInterface(ctx, root, it.ifa_name, family,
                cast(const(ubyte)*) &sa.sin_addr, mask.ptr, 4, it.ifa_flags);
        }
        else if (family == AF_INET6)
        {
            sockaddr_in6* sa = cast(sockaddr_in6*) it.ifa_addr;
            sockaddr_in6* nm = cast(sockaddr_in6*) it.ifa_netmask;
            ubyte[16] mask = void;
            mask[] = 0;
            if (nm !is null)
            {
                auto raw = cast(const(ubyte)*) &nm.sin6_addr;
                foreach (i; 0 .. 16) mask[i] = raw[i];
            }
            addInterface(ctx, root, it.ifa_name, family,
                cast(const(ubyte)*) &sa.sin6_addr, mask.ptr, 16, it.ifa_flags);
        }
    }
    freeifaddrs(list);
    return root;
}
extern(C) JSValue jsOsNetworkInterfaces(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsOsNetworkInterfacesImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsOsUserInfoImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    if (!permissionCheck(Perm.sys, "userInfo"))
        return permissionThrow(ctx, Perm.sys, "userInfo");
    passwd pwd = void;
    passwd* result = null;
    char[16384] buf = void;
    if (getpwuid_r(getuid(), &pwd, buf.ptr, buf.length, &result) != 0 || result is null)
        return throwInternalError(ctx, "getpwuid_r failed");
    JSValue o = JS_NewObject(ctx);
    if (jsIsException(o)) return o;
    JS_SetPropertyStr(ctx, o, "uid", jsInt(cast(int) pwd.pw_uid));
    JS_SetPropertyStr(ctx, o, "gid", jsInt(cast(int) pwd.pw_gid));
    JS_SetPropertyStr(ctx, o, "username", newString(ctx, pwd.pw_name));
    JS_SetPropertyStr(ctx, o, "homedir", newString(ctx, pwd.pw_dir));
    JS_SetPropertyStr(ctx, o, "shell", newString(ctx, pwd.pw_shell));
    return o;
}
extern(C) JSValue jsOsUserInfo(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsOsUserInfoImpl(ctx, thisVal, argc, argv); }

bool installOs(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;

    version (linux)
    {
        setProp(ctx, obj, "platform", newString(ctx, "linux"));
        setProp(ctx, obj, "type", newString(ctx, "Linux"));
    }
    else version (OSX)
    {
        setProp(ctx, obj, "platform", newString(ctx, "darwin"));
        setProp(ctx, obj, "type", newString(ctx, "Darwin"));
    }
    else
    {
        setProp(ctx, obj, "platform", newString(ctx, "unknown"));
        setProp(ctx, obj, "type", newString(ctx, "Unknown"));
    }

    version (X86_64)
        setProp(ctx, obj, "arch", newString(ctx, "x64"));
    else version (AArch64)
        setProp(ctx, obj, "arch", newString(ctx, "arm64"));
    else
        setProp(ctx, obj, "arch", newString(ctx, "unknown"));

    setProp(ctx, obj, "eol", newString(ctx, "\n"));
    setProp(ctx, obj, "devNull", newString(ctx, "/dev/null"));
    setProp(ctx, obj, "endianness", newString(ctx, "LE"));
    bool ok = addNativeFunction(ctx, obj, "tmpdir", &jsOsTmpdir, 0)
        && addNativeFunction(ctx, obj, "homedir", &jsOsHomedir, 0)
        && addNativeFunction(ctx, obj, "hostname", &jsOsHostname, 0)
        && addNativeFunction(ctx, obj, "release", &jsOsRelease, 0)
        && addNativeFunction(ctx, obj, "cpus", &jsOsCpus, 0)
        && addNativeFunction(ctx, obj, "totalmem", &jsOsTotalmem, 0)
        && addNativeFunction(ctx, obj, "freemem", &jsOsFreemem, 0)
        && addNativeFunction(ctx, obj, "uptime", &jsOsUptime, 0)
        && addNativeFunction(ctx, obj, "loadavg", &jsOsLoadavg, 0)
        && addNativeFunction(ctx, obj, "networkInterfaces", &jsOsNetworkInterfaces, 0)
        && addNativeFunction(ctx, obj, "userInfo", &jsOsUserInfo, 0);
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "os", obj) > 0;
}
