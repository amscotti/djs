module djs.apis.net;

// v0.7 networking client. Sockets are POSIX non-blocking descriptors watched by
// libuv poll handles; DNS resolution is a blocking getaddrinfo call in this
// release (documented in COMPAT). The permission gate is checked before any
// descriptor is created, using "host:port" as the resource.

import core.stdc.errno : EAGAIN, EINPROGRESS, EINTR, EWOULDBLOCK, errno;
import core.stdc.stdlib : calloc, free, malloc;
import core.stdc.string : memcpy, strcmp, strcpy, strlen;
import core.sys.posix.netdb : addrinfo, freeaddrinfo, getaddrinfo;
import core.sys.posix.arpa.inet : inet_ntop, inet_pton;
import core.sys.posix.netinet.in_ : AF_INET, AF_INET6, AF_UNSPEC, INADDR_ANY, sockaddr_in, sockaddr_in6, htons, ntohs;
import core.sys.posix.sys.socket : SOCK_STREAM, SO_ERROR, SO_REUSEADDR, SO_REUSEPORT,
    SOL_SOCKET, bind, connect, getsockname, getsockopt, listen, recv, send, setsockopt,
    shutdown, socket, sockaddr, sockaddr_storage, socklen_t;
version (linux)
{
    import core.sys.posix.sys.socket : MSG_NOSIGNAL;
}
else
{
    import core.sys.posix.sys.socket : accept;
    import core.sys.posix.fcntl : F_GETFL, F_SETFD, F_SETFL, FD_CLOEXEC, O_NONBLOCK, fcntl;
}
import core.sys.posix.unistd : close;
import core.sys.posix.sys.types : ssize_t;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.permissions : Perm, permissionCheck, permissionThrow;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.runtime : Runtime, guarded, newTrackedArrayBuffer, runtimeOf, runtimeReportUncaught;

private enum int SOCK_NONBLOCK = 0x800;
private enum int SOCK_CLOEXEC = 0x80000;

version (linux)
{
    extern(C) int accept4(int fd, sockaddr* addr, socklen_t* addrlen, int flags) nothrow @nogc;
}

version (OSX)
{
    // Darwin spells the SIGPIPE opt-out as a socket option, not a send flag.
    private enum int SO_NOSIGPIPE = 0x1022;
    private enum int sendNoSignal = 0;
}
else
{
    private enum int sendNoSignal = MSG_NOSIGNAL;
}

// Create a non-blocking close-on-exec socket. Linux gets it in one call; the
// others set the flags afterwards, and Darwin also has to suppress SIGPIPE per
// socket because send() has no MSG_NOSIGNAL there. @trusted: every step uses
// an fd the caller owns and checks the return value before the fd escapes.
private @trusted int openSocket(int family, int sockType) @nogc nothrow
{
    version (linux)
    {
        return socket(family, sockType | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    }
    else
    {
        int fd = socket(family, sockType, 0);
        if (fd < 0)
            return fd;
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0)
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        version (OSX)
        {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, cast(socklen_t) int.sizeof);
        }
        return fd;
    }
}

// Same setup for a descriptor returned by accept().
private @trusted void adoptSocket(int fd) @nogc nothrow
{
    version (linux)
    {
        // accept4 already did the work.
    }
    else
    {
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0)
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        version (OSX)
        {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, cast(socklen_t) int.sizeof);
        }
    }
}

private struct Listener
{
    bool used;
    int fd;
    uv_poll_t* poll;
    Runtime* rt;
    ulong cb;
    uint port;
}

private enum int maxListeners = 8;
private Listener[maxListeners] listeners;

private NetSock* findSock(uint id) @nogc nothrow
{
    foreach (ref s; socks)
        if (s.used && s.id == id)
            return &s;
    return null;
}

private int freeSockSlot() @nogc nothrow
{
    foreach (i; 0 .. maxSockets)
        if (!socks[i].used) return cast(int) i;
    return -1;
}
private enum int maxSockets = 128;
private enum int readChunk = 65536;

private struct NetSock
{
    bool used;
    int fd;
    uv_poll_t* poll;
    Runtime* rt;
    ulong connectCb;
    ulong readCb;
    ulong writeCb;
    ubyte* wbuf;
    size_t wlen;
    size_t woff;
    bool connected;
    bool reading;
    bool closing;
    bool connecting;
    int connectErr;
    uint id;
}

private NetSock[maxSockets] socks;
private uint nextSockId = 1;

private struct CloseCtx { int fd; }

private extern(C) void pollCloseCb(uv_handle_t* handle) nothrow @nogc
{
    CloseCtx* ctx = cast(CloseCtx*) uv_handle_get_data(handle);
    if (ctx !is null)
    {
        if (ctx.fd >= 0) close(ctx.fd);
        free(ctx);
    }
    free(handle);
}

private void closeSock(NetSock* s, bool releaseCallbacks) @nogc nothrow
{
    if (s is null || !s.used || s.closing)
        return;
    s.closing = true;
    s.used = false;
    if (s.poll !is null)
    {
        uv_poll_stop(s.poll);
        CloseCtx* ctx = cast(CloseCtx*) malloc(CloseCtx.sizeof);
        if (ctx !is null)
        {
            ctx.fd = s.fd;
            uv_handle_set_data(cast(uv_handle_t*) s.poll, ctx);
        }
        else
        {
            close(s.fd);
            uv_handle_set_data(cast(uv_handle_t*) s.poll, null);
        }
        s.fd = -1;
        uv_close(cast(uv_handle_t*) s.poll, &pollCloseCb);
        s.poll = null;
    }
    else if (s.fd >= 0)
    {
        close(s.fd);
        s.fd = -1;
    }
    free(s.wbuf);
    s.wbuf = null;
    s.wlen = s.woff = 0;
    s.id = 0;
    if (releaseCallbacks && s.rt !is null)
    {
        if (s.connectCb != 0) registryRelease(s.rt.ctx, &s.rt.registry, s.connectCb);
        if (s.readCb != 0) registryRelease(s.rt.ctx, &s.rt.registry, s.readCb);
        if (s.writeCb != 0) registryRelease(s.rt.ctx, &s.rt.registry, s.writeCb);
        s.connectCb = s.readCb = s.writeCb = 0;
    }
}

private JSValue netError(JSContext* ctx, int err, const(char)* syscall) @nogc nothrow
{
    import core.stdc.errno : EADDRINUSE, ECONNREFUSED, ECONNRESET, ETIMEDOUT;
    const(char)* code = "EIO";
    const(char)* msg = "network error";
    if (err == ECONNREFUSED) { code = "ECONNREFUSED"; msg = "connection refused"; }
    else if (err == ECONNRESET) { code = "ECONNRESET"; msg = "connection reset"; }
    else if (err == ETIMEDOUT) { code = "ETIMEDOUT"; msg = "connection timed out"; }
    else if (err == EADDRINUSE) { code = "EADDRINUSE"; msg = "address in use"; }
    JSValue e = makeError(ctx, msg, code, null, syscall);
    if (!jsIsException(e))
        JS_SetPropertyStr(ctx, e, "errno", jsInt(err));
    return e;
}

private bool callSlot(Runtime* rt, ulong id, int argc, JSValueConst* argv,
                      bool release) @nogc nothrow
{
    CallbackSlot* slot = registryLookup(&rt.registry, id);
    if (slot is null)
        return false;
    JSValue fn = JS_DupValue(rt.ctx, slot.fn);
    JSValue r = JS_Call(rt.ctx, fn, jsUndefined(), argc, argv);
    JS_FreeValue(rt.ctx, fn);
    if (release)
        registryRelease(rt.ctx, &rt.registry, id);
    if (jsIsException(r))
    {
        JS_FreeValue(rt.ctx, r);
        runtimeReportUncaught(rt, rt.ctx);
        return false;
    }
    JS_FreeValue(rt.ctx, r);
    return true;
}

private extern(C) void pollCb(uv_poll_t* handle, int status, int events) nothrow @nogc
{
    NetSock* s = cast(NetSock*) uv_handle_get_data(cast(uv_handle_t*) handle);
    if (s is null || !s.used || s.closing)
        return;
    Runtime* rt = s.rt;
    if (status < 0)
    {
        int sysErr = -status;
        if (s.connecting && s.fd >= 0)
        {
            int soErr = 0;
            socklen_t sl = cast(socklen_t) int.sizeof;
            if (getsockopt(s.fd, SOL_SOCKET, SO_ERROR, &soErr, &sl) == 0 && soErr != 0)
                sysErr = soErr;
        }
        JSValue err = netError(rt.ctx, sysErr, s.connecting ? "connect" : "poll");
        JSValue[1] argv = [err];
        ulong id = s.connectCb != 0 ? s.connectCb : s.readCb;
        // A write-only socket (connect done, no read callback) can still
        // have a pending write callback: release it here too, or the slot
        // and its JSValue leak when the connection errors out.
        if (id == 0)
            id = s.writeCb;
        s.connecting = false;
        callSlot(rt, id, 1, argv.ptr, true);
        JS_FreeValue(rt.ctx, err);
        s.connectCb = s.readCb = 0;
        s.writeCb = 0;
        closeSock(s, false);
        return;
    }

    if (s.connecting && (events & UV_WRITABLE) != 0)
    {
        int soErr = 0;
        socklen_t sl = cast(socklen_t) int.sizeof;
        getsockopt(s.fd, SOL_SOCKET, SO_ERROR, &soErr, &sl);
        s.connecting = false;
        if (soErr != 0)
        {
            JSValue err = netError(rt.ctx, soErr, "connect");
            JSValue[1] argv = [err];
            callSlot(rt, s.connectCb, 1, argv.ptr, true);
            JS_FreeValue(rt.ctx, err);
            s.connectCb = 0;
            closeSock(s, false);
            return;
        }
        s.connected = true;
        JSValue err = jsNull();
        JSValue idv = jsInt(cast(int) s.id);
        JSValue[2] argv = [err, idv];
        callSlot(rt, s.connectCb, 2, argv.ptr, true);
        s.connectCb = 0;
        if (s.closing)
            return;
        int ev = 0;
        if (s.reading) ev |= UV_READABLE;
        if (s.wbuf !is null) ev |= UV_WRITABLE;
        if (ev != 0) uv_poll_start(s.poll, ev, &pollCb);
        else uv_poll_stop(s.poll);
        return;
    }

    if ((events & UV_READABLE) != 0 && s.reading)
    {
        ubyte* buf = cast(ubyte*) malloc(readChunk);
        if (buf is null)
        {
            JSValue err = netError(rt.ctx, 12, "recv");
            JSValue[1] argv = [err];
            callSlot(rt, s.readCb, 1, argv.ptr, true);
            JS_FreeValue(rt.ctx, err);
            s.readCb = 0;
            closeSock(s, false);
            return;
        }
        ssize_t n;
        do
            n = recv(s.fd, buf, readChunk, 0);
        while (n < 0 && errno == EINTR);
        if (n > 0)
        {
            JSValue chunk = newTrackedArrayBuffer(rt.ctx, rt, buf, cast(size_t) n);
            free(buf);
            JSValue err = jsNull();
            JSValue[2] argv = [err, chunk];
            callSlot(rt, s.readCb, 2, argv.ptr, false);
            JS_FreeValue(rt.ctx, chunk);
        }
        else if (n == 0)
        {
            free(buf);
            JSValue err = jsNull();
            JSValue eof = jsNull();
            JSValue[2] argv = [err, eof];
            callSlot(rt, s.readCb, 2, argv.ptr, true);
            s.readCb = 0;
            closeSock(s, false);
        }
        else if (errno != EAGAIN && errno != EWOULDBLOCK)
        {
            int err = errno;
            free(buf);
            JSValue e = netError(rt.ctx, err, "recv");
            JSValue[1] argv = [e];
            callSlot(rt, s.readCb, 1, argv.ptr, true);
            JS_FreeValue(rt.ctx, e);
            s.readCb = 0;
            closeSock(s, false);
        }
        else
            free(buf);
    }

    if (s.closing)
        return;
    if (s.wbuf !is null && (events & UV_WRITABLE) != 0)
    {
        while (s.woff < s.wlen)
        {
            ssize_t n = send(s.fd, s.wbuf + s.woff, s.wlen - s.woff, sendNoSignal);
            if (n > 0) { s.woff += cast(size_t) n; continue; }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
            if (n < 0 && errno == EINTR) continue;
            int err = errno;
            JSValue e = netError(rt.ctx, err, "write");
            JSValue[1] argv = [e];
            callSlot(rt, s.writeCb, 1, argv.ptr, true);
            JS_FreeValue(rt.ctx, e);
            free(s.wbuf); s.wbuf = null; s.wlen = s.woff = 0;
            s.writeCb = 0;
            closeSock(s, true);
            return;
        }
        free(s.wbuf);
        s.wbuf = null;
        s.wlen = s.woff = 0;
        JSValue e = jsNull();
        JSValue[1] argv = [e];
        ulong cbId = s.writeCb;
        s.writeCb = 0;
        callSlot(rt, cbId, 1, argv.ptr, true);
        // The write callback ran arbitrary JS: it may have destroyed the
        // socket (write-then-end is the common pattern). Re-check before
        // re-arming the poll handle, as the read path does.
        if (s.closing || s.poll is null)
            return;
        int ev = 0;
        if (s.reading) ev |= UV_READABLE;
        if (s.wbuf !is null) ev |= UV_WRITABLE;
        if (ev != 0) uv_poll_start(s.poll, ev, &pollCb); else uv_poll_stop(s.poll);
    }
}

private int findFree() @nogc nothrow
{
    foreach (i; 0 .. maxSockets)
        if (!socks[i].used)
            return i;
    return -1;
}

private struct DnsReq
{
    Runtime* rt;
    ulong cb;
    char* node;
    char* resource;
    addrinfo hints;
    uv_getaddrinfo_t* req;
    bool connect;
    int port;
    int resolve; // 0 = lookup/connect, 4 = resolve A, 6 = resolve AAAA
}

private void dnsFree(DnsReq* d) @nogc nothrow
{
    if (d is null) return;
    free(d.req);
    free(d.node);
    free(d.resource);
    free(d);
}

private void dnsFail(DnsReq* d, int status, int sysErr) @nogc nothrow
{
    JSContext* ctx = d.rt.ctx;
    const(char)* code = (status < 0) ? "ENOTFOUND" : "EAI_FAIL";
    const(char)* msg = (status < 0) ? "getaddrinfo ENOTFOUND" : uv_strerror(status);
    JSValue err = makeError(ctx, msg, code, null, "getaddrinfo");
    if (sysErr != 0 && !jsIsException(err))
        JS_SetPropertyStr(ctx, err, "errno", jsInt(sysErr));
    JSValue[1] argv = [err];
    callSlot(d.rt, d.cb, 1, argv.ptr, true);
    JS_FreeValue(ctx, err);
    dnsFree(d);
}

private extern(C) void dnsCb(uv_getaddrinfo_t* req, int status, addrinfo* res) nothrow @nogc
{
    DnsReq* d = cast(DnsReq*) uv_req_get_data(cast(uv_req_t*) req);
    if (d is null)
        return;
    if (status != 0 || res is null)
    {
        uv_freeaddrinfo(res);
        dnsFail(d, status != 0 ? status : -1, 0);
        return;
    }
    Runtime* rt = d.rt;
    JSContext* ctx = rt.ctx;
    if (d.resolve != 0)
    {
        JSValue arr = JS_NewArray(ctx);
        if (jsIsException(arr)) { uv_freeaddrinfo(res); dnsFree(d); return; }
        uint count = 0;
        char[128] abuf = void;
        char[128][16] seen = void;
        uint seenCount = 0;
        for (addrinfo* ai = res; ai !is null; ai = ai.ai_next)
        {
            if (ai.ai_addr is null) continue;
            const(char)* r = null;
            if (d.resolve == 4 && ai.ai_family == AF_INET)
                r = inet_ntop(AF_INET, &(cast(sockaddr_in*) ai.ai_addr).sin_addr, abuf.ptr, abuf.length);
            else if (d.resolve == 6 && ai.ai_family == AF_INET6)
                r = inet_ntop(AF_INET6, &(cast(sockaddr_in6*) ai.ai_addr).sin6_addr, abuf.ptr, abuf.length);
            if (r is null) continue;
            bool dup = false;
            foreach (i; 0 .. seenCount) if (strcmp(seen[i].ptr, r) == 0) { dup = true; break; }
            if (dup) continue;
            if (seenCount < seen.length) strcpy(seen[seenCount++].ptr, r);
            JS_SetPropertyUint32(ctx, arr, count++, JS_NewStringLen(ctx, r, strlen(r)));
        }
        uv_freeaddrinfo(res);
        if (count == 0)
        {
            JS_FreeValue(ctx, arr);
            dnsFail(d, -1, 0);
            return;
        }
        JSValue err = jsNull();
        JSValue[2] argv = [err, arr];
        callSlot(rt, d.cb, 2, argv.ptr, true);
        JS_FreeValue(ctx, arr);
        dnsFree(d);
        return;
    }
    if (!d.connect)
    {
        char[128] buf = void;
        bool found = false;
        int family = AF_INET;
        // dns.lookup is deterministic for localhost: prefer an IPv4 answer
        // when getaddrinfo supplies one, then fall back to IPv6.
        for (int pass = 0; pass < 2 && !found; ++pass)
        {
            for (addrinfo* ai = res; ai !is null; ai = ai.ai_next)
            {
                if (ai.ai_addr is null) continue;
                if (pass == 0 && ai.ai_family == AF_INET)
                {
                    sockaddr_in* sa = cast(sockaddr_in*) ai.ai_addr;
                    if (inet_ntop(AF_INET, &sa.sin_addr, buf.ptr, buf.length) is null) continue;
                    found = true;
                    family = AF_INET;
                    break;
                }
                if (pass == 1 && ai.ai_family == AF_INET6)
                {
                    sockaddr_in6* s6 = cast(sockaddr_in6*) ai.ai_addr;
                    if (inet_ntop(AF_INET6, &s6.sin6_addr, buf.ptr, buf.length) is null) continue;
                    found = true;
                    family = AF_INET6;
                    break;
                }
            }
        }
        uv_freeaddrinfo(res);
        if (!found)
        {
            dnsFail(d, -1, 0);
            return;
        }
        JSValue err = jsNull();
        JSValue addr = JS_NewStringLen(ctx, buf.ptr, strlen(buf.ptr));
        JSValue fam = jsInt(family == AF_INET6 ? 6 : 4);
        JSValue[3] argv = [err, addr, fam];
        callSlot(rt, d.cb, 3, argv.ptr, true);
        JS_FreeValue(ctx, addr);
        dnsFree(d);
        return;
    }

    int fd = -1;
    int lastErr = 0;
    for (addrinfo* ai = res; ai !is null; ai = ai.ai_next)
    {
        if (ai.ai_addr is null) continue;
        if (ai.ai_family != AF_INET && ai.ai_family != AF_INET6) continue;
        if (ai.ai_family == AF_INET)
            (cast(sockaddr_in*) ai.ai_addr).sin_port = htons(cast(ushort) d.port);
        else
            (cast(sockaddr_in6*) ai.ai_addr).sin6_port = htons(cast(ushort) d.port);
        fd = openSocket(ai.ai_family, SOCK_STREAM);
        if (fd < 0) { lastErr = errno; continue; }
        int rc = connect(fd, ai.ai_addr, ai.ai_addrlen);
        if (rc == 0 || errno == EINPROGRESS)
            break;
        lastErr = errno;
        close(fd);
        fd = -1;
    }
    uv_freeaddrinfo(res);
    if (fd < 0)
    {
        JSValue err = netError(ctx, lastErr, "connect");
        JSValue[1] argv = [err];
        callSlot(rt, d.cb, 1, argv.ptr, true);
        JS_FreeValue(ctx, err);
        dnsFree(d);
        return;
    }

    int idx = findFree();
    if (idx < 0)
    {
        close(fd);
        JSValue err = makeError(ctx, "socket table exhausted", "EMFILE", null, "connect");
        JSValue[1] argv = [err];
        callSlot(rt, d.cb, 1, argv.ptr, true);
        JS_FreeValue(ctx, err);
        dnsFree(d);
        return;
    }
    NetSock* s = &socks[idx];
    *s = NetSock.init;
    s.used = true;
    s.id = nextSockId++;
    if (nextSockId == 0) nextSockId = 1;
    s.fd = fd;
    s.rt = rt;
    s.connecting = true;
    s.connected = false;
    uv_poll_t* poll = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
    if (poll is null)
    {
        close(fd);
        s.used = false;
        JSValue err = makeError(ctx, "out of memory", "ENOMEM", null, "connect");
        JSValue[1] argv = [err];
        callSlot(rt, d.cb, 1, argv.ptr, true);
        JS_FreeValue(ctx, err);
        dnsFree(d);
        return;
    }
    if (uv_poll_init_socket(rt.loop, poll, fd) != 0)
    {
        free(poll); close(fd); s.used = false;
        JSValue err = makeError(ctx, "poll init failed", "EIO", null, "connect");
        JSValue[1] argv = [err];
        callSlot(rt, d.cb, 1, argv.ptr, true);
        JS_FreeValue(ctx, err);
        dnsFree(d);
        return;
    }
    s.poll = poll;
    uv_handle_set_data(cast(uv_handle_t*) poll, s);
    s.connectCb = d.cb; // ownership moves to the socket
    uv_poll_start(poll, UV_WRITABLE, &pollCb);
    dnsFree(d);
}

private JSValue startDns(JSContext* ctx, Runtime* rt, const(char)* host, int port,
                         JSValueConst callback, bool connectMode, int resolveMode = 0) @nogc nothrow
{
    DnsReq* d = cast(DnsReq*) calloc(1, DnsReq.sizeof);
    if (d is null)
        return throwInternalError(ctx, "out of memory");
    d.rt = rt;
    d.connect = connectMode;
    d.port = port;
    d.resolve = resolveMode;
    size_t hl = strlen(host);
    d.node = cast(char*) malloc(hl + 1);
    if (d.node is null) { free(d); return throwInternalError(ctx, "out of memory"); }
    memcpy(d.node, host, hl);
    d.node[hl] = 0;
    d.hints = addrinfo.init;
    d.hints.ai_family = resolveMode == 4 ? AF_INET : resolveMode == 6 ? AF_INET6 : AF_UNSPEC;
    d.hints.ai_socktype = SOCK_STREAM;
    d.req = cast(uv_getaddrinfo_t*) malloc(uv_req_size(UV_GETADDRINFO));
    if (d.req is null) { dnsFree(d); return throwInternalError(ctx, "out of memory"); }
    d.cb = registryAdd(ctx, &rt.registry, callback, null);
    if (d.cb == 0) { dnsFree(d); return throwInternalError(ctx, "callback registry exhausted"); }
    uv_req_set_data(cast(uv_req_t*) d.req, d);
    int rc = uv_getaddrinfo(rt.loop, d.req, &dnsCb, d.node, null, &d.hints);
    if (rc != 0)
    {
        registryRelease(ctx, &rt.registry, d.cb);
        dnsFree(d);
        return throwInternalError(ctx, uv_strerror(rc));
    }
    return jsUndefined();
}


// dns.lookupService: reverse lookup of an IP literal through getnameinfo, the
// same libuv request family the forward resolver uses.
private struct LookupServiceReq
{
    Runtime* rt;
    ulong cb;
    uv_getnameinfo_t* req;
    sockaddr_storage addr;
}

private void lookupServiceFree(LookupServiceReq* d) @nogc nothrow
{
    if (d is null)
        return;
    free(d.req);
    free(d);
}

private extern(C) void lookupServiceCb(uv_getnameinfo_t* req, int status,
                                        const(char)* hostname, const(char)* service) nothrow @nogc
{
    LookupServiceReq* d = cast(LookupServiceReq*) uv_req_get_data(cast(uv_req_t*) req);
    if (d is null)
        return;
    Runtime* rt = d.rt;
    JSContext* ctx = rt.ctx;
    if (status != 0)
    {
        const(char)* msg = uv_strerror(status);
        JSValue err = makeError(ctx, msg, "EAI_FAIL", null, "getnameinfo");
        JSValue[1] argv = [err];
        callSlot(rt, d.cb, 1, argv.ptr, true);
        JS_FreeValue(ctx, err);
        lookupServiceFree(d);
        return;
    }
    const(char)* h = hostname !is null ? hostname : "";
    const(char)* v = service !is null ? service : "";
    JSValue host = JS_NewStringLen(ctx, h, strlen(h));
    JSValue svc = JS_NewStringLen(ctx, v, strlen(v));
    JSValue[3] argv = [jsNull(), host, svc];
    callSlot(rt, d.cb, 3, argv.ptr, true);
    JS_FreeValue(ctx, host);
    JS_FreeValue(ctx, svc);
    lookupServiceFree(d);
}

private JSValue startLookupService(JSContext* ctx, Runtime* rt, const(char)* addr, int port,
                                   JSValueConst callback) @nogc nothrow
{
    LookupServiceReq* d = cast(LookupServiceReq*) calloc(1, LookupServiceReq.sizeof);
    if (d is null)
        return throwInternalError(ctx, "out of memory");
    d.rt = rt;
    sockaddr_in* v4 = cast(sockaddr_in*) &d.addr;
    sockaddr_in6* v6 = cast(sockaddr_in6*) &d.addr;
    if (inet_pton(AF_INET, addr, &v4.sin_addr) == 1)
    {
        v4.sin_family = AF_INET;
        v4.sin_port = htons(cast(ushort) port);
    }
    else if (inet_pton(AF_INET6, addr, &v6.sin6_addr) == 1)
    {
        v6.sin6_family = AF_INET6;
        v6.sin6_port = htons(cast(ushort) port);
    }
    else
    {
        free(d);
        return throwTypeError(ctx, "lookupService requires an IP address");
    }
    d.req = cast(uv_getnameinfo_t*) malloc(uv_req_size(UV_GETNAMEINFO));
    if (d.req is null)
    {
        lookupServiceFree(d);
        return throwInternalError(ctx, "out of memory");
    }
    d.cb = registryAdd(ctx, &rt.registry, callback, null);
    if (d.cb == 0)
    {
        lookupServiceFree(d);
        return throwInternalError(ctx, "callback registry exhausted");
    }
    uv_req_set_data(cast(uv_req_t*) d.req, d);
    int rc = uv_getnameinfo(rt.loop, d.req, &lookupServiceCb,
                            cast(const(sockaddr)*) &d.addr, 0);
    if (rc != 0)
    {
        registryRelease(ctx, &rt.registry, d.cb);
        lookupServiceFree(d);
        return throwInternalError(ctx, uv_strerror(rc));
    }
    return jsUndefined();
}

private extern(C) JSValue jsNetLookupServiceImpl(JSContext* ctx, JSValueConst, int argc,
                                                 JSValueConst* argv) nothrow @nogc
{
    if (argc < 3 || !jsIsString(argv[0]) || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "lookupService requires (address, port, callback)");
    int port = 0;
    if (!toInt32(ctx, argv[1], &port) || port < 0 || port > 65535)
        return throwRangeError(ctx, "port out of range");
    const(char)* addr = null;
    size_t alen = 0;
    if (!toStringView(ctx, argv[0], &addr, &alen))
        return jsException();
    if (!permissionCheck(Perm.net, addr))
    {
        JSValue e = permissionThrow(ctx, Perm.net, addr);
        JS_FreeCString(ctx, addr);
        return e;
    }
    Runtime* rt = runtimeOf(ctx);
    JSValue r = startLookupService(ctx, rt, addr, port, argv[2]);
    JS_FreeCString(ctx, addr);
    return r;
}
extern(C) JSValue jsNetLookupService(JSContext* ctx, JSValueConst thisVal, int argc,
                                     JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetLookupServiceImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetResolveStartImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    if (argc < 3 || !jsIsString(argv[0]) || !jsIsString(argv[1]) || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "resolve requires (host, type, callback)");
    const(char)* host = null; size_t hlen = 0;
    const(char)* kind = null; size_t klen = 0;
    if (!toStringView(ctx, argv[0], &host, &hlen)) return jsException();
    if (!toStringView(ctx, argv[1], &kind, &klen)) { JS_FreeCString(ctx, host); return jsException(); }
    int mode = 0;
    if (klen == 1 && (kind[0] == 'A' || kind[0] == 'a')) mode = 4;
    else if (klen == 4 && (kind[0] == 'A' || kind[0] == 'a')) mode = 6;
    JS_FreeCString(ctx, kind);
    if (mode == 0) { JS_FreeCString(ctx, host); return throwTypeError(ctx, "only A and AAAA records are supported"); }
    if (!permissionCheck(Perm.net, host))
    {
        JSValue e = permissionThrow(ctx, Perm.net, host);
        JS_FreeCString(ctx, host);
        return e;
    }
    Runtime* rt = runtimeOf(ctx);
    JSValue r = startDns(ctx, rt, host, 0, argv[2], false, mode);
    JS_FreeCString(ctx, host);
    return r;
}
extern(C) JSValue jsNetResolveStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                    JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetResolveStartImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetLookupStartImpl(JSContext* ctx, JSValueConst, int argc,
                                              JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "lookup requires (host, callback)");
    const(char)* host = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[0], &host, &len))
        return jsException();
    if (!permissionCheck(Perm.net, host))
    {
        JSValue e = permissionThrow(ctx, Perm.net, host);
        JS_FreeCString(ctx, host);
        return e;
    }
    Runtime* rt = runtimeOf(ctx);
    JSValue r = startDns(ctx, rt, host, 0, argv[1], false);
    JS_FreeCString(ctx, host);
    return r;
}
extern(C) JSValue jsNetLookupStart(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetLookupStartImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetConnectImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    if (argc < 3 || !jsIsString(argv[0]) || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "connect requires (host, port, callback)");
    int port = 0;
    if (!toInt32(ctx, argv[1], &port) || port < 1 || port > 65535)
        return throwRangeError(ctx, "port out of range");
    const(char)* host = null;
    size_t hlen = 0;
    if (!toStringView(ctx, argv[0], &host, &hlen))
        return jsException();
    char[300] resource = void;
    import core.stdc.stdio : snprintf;
    snprintf(resource.ptr, resource.length, "%.*s:%d", cast(int) hlen, host, port);
    if (!permissionCheck(Perm.net, resource.ptr))
    {
        JSValue e = permissionThrow(ctx, Perm.net, resource.ptr);
        JS_FreeCString(ctx, host);
        return e;
    }
    Runtime* rt = runtimeOf(ctx);
    JSValue r = startDns(ctx, rt, host, port, argv[2], true);
    JS_FreeCString(ctx, host);
    return r;
}
extern(C) JSValue jsNetConnect(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetConnectImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetStartReadImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "startRead requires (id, callback)");
    NetSock* s = findSock(cast(uint) id);
    if (s is null) return throwTypeError(ctx, "invalid socket");
    if (s.readCb != 0)
        registryRelease(s.rt.ctx, &s.rt.registry, s.readCb);
    s.readCb = registryAdd(ctx, &s.rt.registry, argv[1], null);
    s.reading = true;
    if (s.connected && s.poll !is null)
    {
        int ev = UV_READABLE;
        if (s.wbuf !is null) ev |= UV_WRITABLE;
        uv_poll_start(s.poll, ev, &pollCb);
    }
    return jsUndefined();
}
extern(C) JSValue jsNetStartRead(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetStartReadImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetWriteImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 3 || !toInt32(ctx, argv[0], &id) || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "write requires (id, data, callback)");
    NetSock* s = findSock(cast(uint) id);
    if (s is null) return throwTypeError(ctx, "invalid socket");
    size_t len = 0;
    const(char)* str = null;
    size_t slen = 0;
    ubyte* copy = null;
    if (jsIsString(argv[1]))
    {
        if (!toStringView(ctx, argv[1], &str, &slen))
            return jsException();
        copy = cast(ubyte*) malloc(slen > 0 ? slen : 1);
        if (copy is null) { JS_FreeCString(ctx, str); return throwInternalError(ctx, "out of memory"); }
        memcpy(copy, str, slen);
        JS_FreeCString(ctx, str);
        len = slen;
    }
    else
    {
        ubyte* src = JS_GetUint8Array(ctx, &len, argv[1]);
        if (src is null) return jsException();
        copy = cast(ubyte*) malloc(len > 0 ? len : 1);
        if (copy is null) return throwInternalError(ctx, "out of memory");
        memcpy(copy, src, len);
    }
    free(s.wbuf);
    s.wbuf = copy;
    s.wlen = len;
    s.woff = 0;
    if (s.writeCb != 0)
        registryRelease(s.rt.ctx, &s.rt.registry, s.writeCb);
    s.writeCb = registryAdd(ctx, &s.rt.registry, argv[2], null);
    if (s.poll !is null)
        uv_poll_start(s.poll, UV_WRITABLE | (s.reading ? UV_READABLE : 0), &pollCb);
    return jsUndefined();
}
extern(C) JSValue jsNetWrite(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetWriteImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetShutdownImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "shutdown requires an id");
    NetSock* s = findSock(cast(uint) id);
    if (s is null) return jsUndefined();
    shutdown(s.fd, 1);
    return jsUndefined();
}
extern(C) JSValue jsNetShutdown(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetShutdownImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetCloseImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "close requires an id");
    // Ids come from a monotonic counter, not a slot index: any id >= 1 may
    // name a live socket. An upper bound here would strand every socket
    // created after the table's first full generation.
    if (id < 1)
        return jsUndefined();
    NetSock* s = findSock(cast(uint) id);
    if (s.used)
        closeSock(s, true);
    return jsUndefined();
}
extern(C) JSValue jsNetClose(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetCloseImpl(ctx, thisVal, argc, argv); }

void netCloseAll(Runtime* rt) @nogc nothrow
{
    foreach (ref s; socks)
        if (s.used && s.rt is rt)
            closeSock(&s, true);
}


private extern(C) void listenerHandleClose(uv_handle_t* h) nothrow @nogc { free(h); }

private void closeListenerHandle(Listener* l) @nogc nothrow
{
    if (l is null || l.poll is null) return;
    uv_poll_stop(l.poll);
    CloseCtx* ctx = cast(CloseCtx*) malloc(CloseCtx.sizeof);
    if (ctx !is null)
    {
        ctx.fd = l.fd;
        uv_handle_set_data(cast(uv_handle_t*) l.poll, ctx);
        uv_close(cast(uv_handle_t*) l.poll, &pollCloseCb);
    }
    else
    {
        uv_close(cast(uv_handle_t*) l.poll, &listenerHandleClose);
        if (l.fd >= 0) close(l.fd);
    }
    l.poll = null;
    l.fd = -1;
    if (l.cb != 0 && l.rt !is null)
        registryRelease(l.rt.ctx, &l.rt.registry, l.cb);
    l.cb = 0;
    l.used = false;
}

private extern(C) void handleOnlyCloseCb(uv_handle_t* h) nothrow @nogc { free(h); }

// Hand a socket's descriptor to another subsystem (TLS) without closing it.
// The poll handle is stopped and freed; the caller owns the fd afterwards.
private extern(C) JSValue jsNetDetachFdImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "detachFd requires a socket id");
    NetSock* s = findSock(cast(uint) id);
    if (s is null) return throwTypeError(ctx, "invalid socket");
    int fd = s.fd;
    if (s.poll !is null)
    {
        uv_poll_stop(s.poll);
        uv_close(cast(uv_handle_t*) s.poll, &handleOnlyCloseCb);
    }
    s.poll = null;
    s.fd = -1;
    s.used = false;
    s.id = 0;
    if (s.readCb != 0 && s.rt !is null) registryRelease(s.rt.ctx, &s.rt.registry, s.readCb);
    if (s.writeCb != 0 && s.rt !is null) registryRelease(s.rt.ctx, &s.rt.registry, s.writeCb);
    if (s.connectCb != 0 && s.rt !is null) registryRelease(s.rt.ctx, &s.rt.registry, s.connectCb);
    if (s.wbuf !is null) free(s.wbuf);
    s.wbuf = null;
    s.wlen = s.woff = 0;
    s.readCb = 0;
    s.writeCb = 0;
    s.connectCb = 0;
    return jsInt(fd);
}
extern(C) JSValue jsNetDetachFd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetDetachFdImpl(ctx, thisVal, argc, argv); }

private extern(C) void listenerCb(uv_poll_t* h, int status, int events) nothrow @nogc
{
    Listener* l = cast(Listener*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (l is null || !l.used || status < 0 || (events & UV_READABLE) == 0)
        return;
    while (true)
    {
        version (linux)
        {
            int cfd = accept4(l.fd, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (cfd < 0) return;
        }
        else
        {
            int cfd = accept(l.fd, null, null);
            if (cfd < 0) return;
            adoptSocket(cfd);
        }
        int slot = freeSockSlot();
        if (slot < 0) { close(cfd); continue; }
        NetSock* s = &socks[slot];
        *s = NetSock.init;
        s.used = true;
        s.id = nextSockId++;
        if (nextSockId == 0) nextSockId = 1;
        s.fd = cfd;
        s.rt = l.rt;
        s.connected = true;
        uv_poll_t* p = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
        if (p is null || uv_poll_init_socket(l.rt.loop, p, cfd) != 0)
        {
            if (p !is null) free(p);
            close(cfd);
            s.used = false;
            continue;
        }
        s.poll = p;
        uv_handle_set_data(cast(uv_handle_t*) p, s);
        JSValue idv = jsInt(cast(int) s.id);
        callSlot(l.rt, l.cb, 1, &idv, false);
    }
}

private extern(C) JSValue jsNetListenImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    import core.stdc.stdio : snprintf;
    if (argc < 3 || !jsIsString(argv[0]) || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "listen requires (host, port, callback)");
    int port = 0;
    if (!toInt32(ctx, argv[1], &port) || port < 0 || port > 65535)
        return throwRangeError(ctx, "port out of range");
    bool reusePort = argc > 3 && JS_ToBool(ctx, argv[3]) > 0;
    const(char)* host = null;
    size_t hlen = 0;
    if (!toStringView(ctx, argv[0], &host, &hlen))
        return jsException();
    scope(exit) JS_FreeCString(ctx, host);
    char[320] resource = void;
    snprintf(resource.ptr, resource.length, "%.*s:%d", cast(int) hlen, host, port);
    if (!permissionCheck(Perm.listen, resource.ptr))
        return permissionThrow(ctx, Perm.listen, resource.ptr);
    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");
    bool v6 = false;
    for (size_t i = 0; i < hlen; ++i) if (host[i] == ':') { v6 = true; break; }
    const(char)* use = host;
    if (hlen == 0 || (hlen == 9 && host[0 .. 9] == "localhost")) use = "127.0.0.1";
    if (hlen == 1 && host[0] == '*') use = v6 ? "::" : "0.0.0.0";
    int fd = -1;
    if (v6)
    {
        sockaddr_in6 sa6 = void;
        sa6.sin6_family = AF_INET6;
        sa6.sin6_port = htons(cast(ushort) port);
        if (inet_pton(AF_INET6, use, &sa6.sin6_addr) != 1)
            return throwTypeError(ctx, "invalid listen address");
        fd = openSocket(AF_INET6, SOCK_STREAM);
        if (fd < 0) return throwError(ctx, netError(ctx, errno, "socket"));
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, cast(socklen_t) int.sizeof);
        if (reusePort) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, cast(socklen_t) int.sizeof);
        if (bind(fd, cast(sockaddr*) &sa6, cast(socklen_t) sockaddr_in6.sizeof) != 0 || listen(fd, 128) != 0)
        {
            int e = errno;
            close(fd);
            return throwError(ctx, netError(ctx, e, "listen"));
        }
    }
    else
    {
        sockaddr_in sa = void;
        sa.sin_family = AF_INET;
        sa.sin_port = htons(cast(ushort) port);
        if (inet_pton(AF_INET, use, &sa.sin_addr) != 1)
            return throwTypeError(ctx, "invalid listen address");
        fd = openSocket(AF_INET, SOCK_STREAM);
        if (fd < 0) return throwError(ctx, netError(ctx, errno, "socket"));
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, cast(socklen_t) int.sizeof);
        if (reusePort) setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, cast(socklen_t) int.sizeof);
        if (bind(fd, cast(sockaddr*) &sa, cast(socklen_t) sockaddr_in.sizeof) != 0 || listen(fd, 128) != 0)
        {
            int e = errno;
            close(fd);
            return throwError(ctx, netError(ctx, e, "listen"));
        }
    }
    int slot = -1;
    foreach (i; 0 .. maxListeners) if (!listeners[i].used) { slot = cast(int) i; break; }
    if (slot < 0)
    {
        close(fd);
        return throwInternalError(ctx, "listener table exhausted");
    }
    Listener* l = &listeners[slot];
    uv_poll_t* p = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
    if (p is null || uv_poll_init_socket(rt.loop, p, fd) != 0)
    {
        if (p !is null) free(p);
        close(fd);
        return throwInternalError(ctx, "poll init failed");
    }
    l.used = true;
    l.fd = fd;
    l.poll = p;
    l.rt = rt;
    l.cb = registryAdd(ctx, &rt.registry, argv[2], null);
    if (l.cb == 0)
    {
        l.fd = fd;
        l.poll = p;
        closeListenerHandle(l);
        return throwInternalError(ctx, "callback registry exhausted");
    }
    uv_handle_set_data(cast(uv_handle_t*) p, l);
    uv_poll_start(p, UV_READABLE, &listenerCb);
    return jsInt(cast(int) slot + 1);
}
extern(C) JSValue jsNetListen(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetListenImpl(ctx, thisVal, argc, argv); }

private Listener* findListener(int id) @nogc nothrow
{
    if (id < 1 || id > maxListeners) return null;
    Listener* l = &listeners[id - 1];
    return (l.used && l.poll !is null) ? l : null;
}

private extern(C) JSValue jsNetListenerPortImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "listenerPort requires an id");
    Listener* l = findListener(id);
    if (l is null) return jsInt(0);
    sockaddr_in sa = void;
    socklen_t sl = cast(socklen_t) sockaddr_in.sizeof;
    if (getsockname(l.fd, cast(sockaddr*) &sa, &sl) != 0)
        return jsInt(0);
    return jsInt(ntohs(sa.sin_port));
}
extern(C) JSValue jsNetListenerPort(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetListenerPortImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsNetCloseListenerImpl(JSContext* ctx, JSValueConst, int argc,
                                                 JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "closeListener requires an id");
    Listener* l = findListener(id);
    if (l is null) return jsUndefined();
    closeListenerHandle(l);
    return jsUndefined();
}
extern(C) JSValue jsNetCloseListener(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsNetCloseListenerImpl(ctx, thisVal, argc, argv); }

bool installNet(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "lookupStart", &jsNetLookupStart, 2)
        && addNativeFunction(ctx, obj, "resolveStart", &jsNetResolveStart, 3)
        && addNativeFunction(ctx, obj, "lookupService", &jsNetLookupService, 3)
        && addNativeFunction(ctx, obj, "connect", &jsNetConnect, 3)
        && addNativeFunction(ctx, obj, "startRead", &jsNetStartRead, 2)
        && addNativeFunction(ctx, obj, "write", &jsNetWrite, 3)
        && addNativeFunction(ctx, obj, "shutdown", &jsNetShutdown, 1)
        && addNativeFunction(ctx, obj, "end", &jsNetShutdown, 1)
        && addNativeFunction(ctx, obj, "close", &jsNetClose, 1)
        && addNativeFunction(ctx, obj, "listen", &jsNetListen, 3)
        && addNativeFunction(ctx, obj, "listenerPort", &jsNetListenerPort, 1)
        && addNativeFunction(ctx, obj, "closeListener", &jsNetCloseListener, 1)
        && addNativeFunction(ctx, obj, "detachFd", &jsNetDetachFd, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "net", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
