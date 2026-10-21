module djs.apis.dgram;

// IPv4 UDP sockets. One non-blocking descriptor per socket polled by libuv;
// sendto/recvfrom are non-blocking so a busy datagram socket cannot stall the
// loop. The permission resource is "host:port" for both bind and send.

import core.stdc.errno : EAGAIN, EINTR, EWOULDBLOCK, errno;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy;
import core.sys.posix.arpa.inet : inet_ntop, inet_pton;
import core.sys.posix.netinet.in_ : AF_INET, in_addr, sockaddr_in, htons, ntohs;
import core.sys.posix.sys.socket : SOCK_DGRAM, SO_BROADCAST, SOL_SOCKET, bind, getsockname,
    recvfrom, sendto, setsockopt, socket, sockaddr, socklen_t;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd : close;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.permissions : Perm, permissionCheck, permissionThrow;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;

private enum int SOCK_NONBLOCK = 0x800;
// Linux socket-level constants not exported by druntime's posix bindings.
private enum int IPPROTO_IP = 0;
private enum int IP_TTL = 2;
private enum int IP_MULTICAST_TTL = 33;
private enum int IP_ADD_MEMBERSHIP = 35;
private enum int IP_DROP_MEMBERSHIP = 36;
private enum int SOCK_CLOEXEC = 0x80000;
private enum int maxSocks = 8;
private enum int datagramChunk = 65536;

private struct DgramSock
{
    bool used;
    int fd;
    uv_poll_t* poll;
    Runtime* rt;
    ulong recvCb;
    char[64] addr;
    uint port;
}

private DgramSock[maxSocks] socks;

private extern(C) void dgramClose(uv_handle_t* h) nothrow @nogc { free(h); }

private DgramSock* find(int id) @nogc nothrow
{
    if (id < 1 || id > maxSocks) return null;
    return socks[id - 1].used ? &socks[id - 1] : null;
}

private void release(DgramSock* s) @nogc nothrow
{
    if (s is null || !s.used) return;
    if (s.poll !is null)
    {
        uv_poll_stop(s.poll);
        uv_close(cast(uv_handle_t*) s.poll, &dgramClose);
        s.poll = null;
    }
    if (s.recvCb != 0 && s.rt !is null)
        registryRelease(s.rt.ctx, &s.rt.registry, s.recvCb);
    s.recvCb = 0;
    if (s.fd >= 0) { close(s.fd); s.fd = -1; }
    s.used = false;
}

private extern(C) void recvCb(uv_poll_t* h, int status, int events) nothrow @nogc
{
    DgramSock* s = cast(DgramSock*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (s is null || !s.used || status < 0 || (events & UV_READABLE) == 0) return;
    if (s.recvCb == 0 || s.rt is null) return;
    CallbackSlot* slot = registryLookup(&s.rt.registry, s.recvCb);
    if (slot is null) return;
    ubyte* buf = cast(ubyte*) malloc(datagramChunk);
    if (buf is null) return;
    sockaddr_in from = void;
    socklen_t flen = cast(socklen_t) sockaddr_in.sizeof;
    ssize_t n = recvfrom(s.fd, buf, datagramChunk, 0, cast(sockaddr*) &from, &flen);
    if (n < 0)
    {
        free(buf);
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
        JSValue err = makeError(s.rt.ctx, "recvfrom failed", "EIO", null, "recvfrom");
        JSValue[3] argv = [err, jsUndefined(), jsUndefined()];
        JSValue fn = JS_DupValue(s.rt.ctx, slot.fn);
        JSValue r = JS_Call(s.rt.ctx, fn, jsUndefined(), 3, argv.ptr);
        JS_FreeValue(s.rt.ctx, fn);
        JS_FreeValue(s.rt.ctx, err);
        if (jsIsException(r)) { JS_FreeValue(s.rt.ctx, r); runtimeReportUncaught(s.rt, s.rt.ctx); }
        else JS_FreeValue(s.rt.ctx, r);
        return;
    }
    char[64] text = void;
    const(char)* p = inet_ntop(AF_INET, &from.sin_addr, text.ptr, text.length);
    JSValue rinfo = JS_NewObject(s.rt.ctx);
    JS_SetPropertyStr(s.rt.ctx, rinfo, "address", newString(s.rt.ctx, p !is null ? p : "0.0.0.0"));
    JS_SetPropertyStr(s.rt.ctx, rinfo, "family", newString(s.rt.ctx, "IPv4"));
    JS_SetPropertyStr(s.rt.ctx, rinfo, "port", jsInt(ntohs(from.sin_port)));
    JSValue data = JS_NewArrayBufferCopy(s.rt.ctx, buf, cast(size_t) n);
    free(buf);
    JSValue[3] argv = [jsNull(), data, rinfo];
    JSValue fn = JS_DupValue(s.rt.ctx, slot.fn);
    JSValue r = JS_Call(s.rt.ctx, fn, jsUndefined(), 3, argv.ptr);
    JS_FreeValue(s.rt.ctx, fn);
    JS_FreeValue(s.rt.ctx, data);
    JS_FreeValue(s.rt.ctx, rinfo);
    if (jsIsException(r)) { JS_FreeValue(s.rt.ctx, r); runtimeReportUncaught(s.rt, s.rt.ctx); }
    else JS_FreeValue(s.rt.ctx, r);
}

private extern(C) JSValue jsCreateImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int slot = -1;
    foreach (i; 0 .. maxSocks) if (!socks[i].used) { slot = cast(int) i; break; }
    if (slot < 0) return throwInternalError(ctx, "dgram table exhausted");
    Runtime* rt = runtimeOf(ctx);
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return makeError(ctx, "socket failed", "EIO", null, "socket");
    uv_poll_t* p = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
    if (p is null || uv_poll_init_socket(rt.loop, p, fd) != 0)
    {
        if (p !is null) free(p);
        close(fd);
        return throwInternalError(ctx, "poll init failed");
    }
    DgramSock* s = &socks[slot];
    s.used = true;
    s.fd = fd;
    s.poll = p;
    s.rt = rt;
    s.recvCb = 0;
    uv_handle_set_data(cast(uv_handle_t*) p, s);
    return jsInt(slot + 1);
}
extern(C) JSValue jsCreate(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCreateImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsBindImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    import core.stdc.stdio : snprintf;
    int id = 0, port = 0;
    if (argc < 3 || !toInt32(ctx, argv[0], &id) || !toInt32(ctx, argv[2], &port))
        return throwTypeError(ctx, "dgram.bind requires (id, host, port)");
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    const(char)* host = null;
    size_t hlen = 0;
    if (!toStringView(ctx, argv[1], &host, &hlen)) return jsException();
    scope(exit) JS_FreeCString(ctx, host);
    char[320] resource = void;
    snprintf(resource.ptr, resource.length, "%.*s:%d", cast(int) hlen, host, port);
    if (!permissionCheck(Perm.net, resource.ptr))
        return permissionThrow(ctx, Perm.net, resource.ptr);
    sockaddr_in sa = void;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(cast(ushort) port);
    const(char)* use = (hlen == 0) ? "0.0.0.0" : host;
    if (inet_pton(AF_INET, use, &sa.sin_addr) != 1)
        return throwTypeError(ctx, "only IPv4 bind addresses are supported");
    if (bind(s.fd, cast(sockaddr*) &sa, cast(socklen_t) sockaddr_in.sizeof) != 0)
        return makeError(ctx, "bind failed", "EADDRINUSE", null, "bind");
    socklen_t sl = cast(socklen_t) sockaddr_in.sizeof;
    if (getsockname(s.fd, cast(sockaddr*) &sa, &sl) == 0)
        s.port = ntohs(sa.sin_port);
    return jsInt(cast(int) s.port);
}
extern(C) JSValue jsBind(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsBindImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsStartRecvImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "dgram.startRecv requires (id, callback)");
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    if (s.recvCb != 0) registryRelease(s.rt.ctx, &s.rt.registry, s.recvCb);
    s.recvCb = registryAdd(ctx, &s.rt.registry, argv[1], null);
    uv_poll_start(s.poll, UV_READABLE, &recvCb);
    return jsUndefined();
}
extern(C) JSValue jsStartRecv(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStartRecvImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsSendImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    import core.stdc.stdio : snprintf;
    int id = 0, port = 0;
    if (argc < 4 || !toInt32(ctx, argv[0], &id) || !toInt32(ctx, argv[2], &port))
        return throwTypeError(ctx, "dgram.send requires (id, host, port, data)");
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    const(char)* host = null;
    size_t hlen = 0;
    if (!toStringView(ctx, argv[1], &host, &hlen)) return jsException();
    scope(exit) JS_FreeCString(ctx, host);
    char[320] resource = void;
    snprintf(resource.ptr, resource.length, "%.*s:%d", cast(int) hlen, host, port);
    if (!permissionCheck(Perm.net, resource.ptr))
        return permissionThrow(ctx, Perm.net, resource.ptr);
    size_t len = 0;
    ubyte* data = JS_GetArrayBuffer(ctx, &len, argv[3]);
    if (data is null)
    {
        size_t off = 0, n = 0, bpe = 0;
        JSValue ab = JS_GetTypedArrayBuffer(ctx, argv[3], &off, &n, &bpe);
        if (jsIsException(ab)) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "data must be bytes"); }
        size_t size = 0;
        ubyte* base = JS_GetArrayBuffer(ctx, &size, ab);
        if (base is null || off > size || n > size - off) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "data must be bytes"); }
        data = base + off;
        len = n;
        JS_FreeValue(ctx, ab);
    }
    sockaddr_in sa = void;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(cast(ushort) port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1)
        return throwTypeError(ctx, "only IPv4 send addresses are supported");
    ssize_t n = sendto(s.fd, data, len, 0, cast(sockaddr*) &sa, cast(socklen_t) sockaddr_in.sizeof);
    if (n < 0) return makeError(ctx, "sendto failed", "EIO", null, "sendto");
    return jsInt(cast(int) n);
}
extern(C) JSValue jsSend(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSendImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsAddressImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "dgram.address requires an id");
    DgramSock* s = find(id);
    if (s is null) return jsNull();
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "address", newString(ctx, "0.0.0.0"));
    JS_SetPropertyStr(ctx, o, "family", newString(ctx, "IPv4"));
    JS_SetPropertyStr(ctx, o, "port", jsInt(s.port));
    return o;
}
extern(C) JSValue jsAddress(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsAddressImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCloseImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "dgram.close requires an id");
    DgramSock* s = find(id);
    if (s !is null) release(s);
    return jsUndefined();
}
extern(C) JSValue jsClose(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCloseImpl(ctx, thisVal, argc, argv); }


private struct ip_mreq
{
    in_addr imr_multiaddr;
    in_addr imr_interface;
}

private extern(C) JSValue jsSetBroadcastImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id))
        return throwTypeError(ctx, "setBroadcast requires (id, flag)");
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    int one = JS_ToBool(ctx, argv[1]) > 0 ? 1 : 0;
    if (setsockopt(s.fd, SOL_SOCKET, SO_BROADCAST, &one, cast(socklen_t) int.sizeof) != 0)
        return makeError(ctx, "setsockopt failed", "EIO", null, "setsockopt");
    return jsUndefined();
}
extern(C) JSValue jsSetBroadcast(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSetBroadcastImpl(ctx, thisVal, argc, argv); }

private JSValue setIntOpt(JSContext* ctx, int id, int level, int opt, JSValueConst val) @nogc nothrow
{
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    int v = 0;
    if (!toInt32(ctx, val, &v)) return throwTypeError(ctx, "option requires a number");
    if (setsockopt(s.fd, level, opt, &v, cast(socklen_t) int.sizeof) != 0)
        return makeError(ctx, "setsockopt failed", "EIO", null, "setsockopt");
    return jsUndefined();
}

private extern(C) JSValue jsSetTTLImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "setTTL requires (id, ttl)");
    return setIntOpt(ctx, id, IPPROTO_IP, IP_TTL, argv[1]);
}
extern(C) JSValue jsSetTTL(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSetTTLImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsSetMulticastTTLImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "setMulticastTTL requires (id, ttl)");
    return setIntOpt(ctx, id, IPPROTO_IP, IP_MULTICAST_TTL, argv[1]);
}
extern(C) JSValue jsSetMulticastTTL(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSetMulticastTTLImpl(ctx, thisVal, argc, argv); }

private JSValue membership(JSContext* ctx, int id, int opt, const(char)* addr) @nogc nothrow
{
    DgramSock* s = find(id);
    if (s is null) return throwTypeError(ctx, "invalid dgram socket");
    char[320] resource = void;
    import core.stdc.stdio : snprintf;
    snprintf(resource.ptr, resource.length, "%s:0", addr);
    if (!permissionCheck(Perm.net, resource.ptr))
        return permissionThrow(ctx, Perm.net, resource.ptr);
    ip_mreq req = void;
    if (inet_pton(AF_INET, addr, &req.imr_multiaddr) != 1)
        return throwTypeError(ctx, "invalid multicast address");
    req.imr_interface.s_addr = 0;
    if (setsockopt(s.fd, IPPROTO_IP, opt, &req, cast(socklen_t) ip_mreq.sizeof) != 0)
        return makeError(ctx, "multicast membership failed", "EIO", null, "setsockopt");
    return jsUndefined();
}

private extern(C) JSValue jsAddMembershipImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "addMembership requires (id, address)");
    const(char)* addr = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[1], &addr, &len)) return jsException();
    scope(exit) JS_FreeCString(ctx, addr);
    return membership(ctx, id, IP_ADD_MEMBERSHIP, addr);
}
extern(C) JSValue jsAddMembership(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsAddMembershipImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsDropMembershipImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int id = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &id)) return throwTypeError(ctx, "dropMembership requires (id, address)");
    const(char)* addr = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[1], &addr, &len)) return jsException();
    scope(exit) JS_FreeCString(ctx, addr);
    return membership(ctx, id, IP_DROP_MEMBERSHIP, addr);
}
extern(C) JSValue jsDropMembership(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsDropMembershipImpl(ctx, thisVal, argc, argv); }

void dgramCloseAll(Runtime* self) @nogc nothrow
{
    foreach (ref s; socks)
        if (s.used && s.rt is self)
            release(&s);
}

bool installDgram(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "create", &jsCreate, 0)
        && addNativeFunction(ctx, obj, "bind", &jsBind, 3)
        && addNativeFunction(ctx, obj, "startRecv", &jsStartRecv, 2)
        && addNativeFunction(ctx, obj, "send", &jsSend, 4)
        && addNativeFunction(ctx, obj, "address", &jsAddress, 1)
        && addNativeFunction(ctx, obj, "close", &jsClose, 1)
        && addNativeFunction(ctx, obj, "setBroadcast", &jsSetBroadcast, 2)
        && addNativeFunction(ctx, obj, "setTTL", &jsSetTTL, 2)
        && addNativeFunction(ctx, obj, "setMulticastTTL", &jsSetMulticastTTL, 2)
        && addNativeFunction(ctx, obj, "addMembership", &jsAddMembership, 2)
        && addNativeFunction(ctx, obj, "dropMembership", &jsDropMembership, 2);
    if (!ok || JS_SetPropertyStr(ctx, djs, "dgram", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
