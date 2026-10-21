module djs.apis.zlib;

// zlib/gzip/deflate bindings. The stream table backs both the one-shot helpers
// (create/write/end called in sequence from the prelude) and the Transform
// streams, so compressed output is a single zlib stream rather than a
// concatenation of independently compressed chunks.

import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.runtime : Runtime, guarded, runtimeOf;

private struct z_stream
{
    const(ubyte)* next_in;
    uint avail_in;
    ulong total_in;
    ubyte* next_out;
    uint avail_out;
    ulong total_out;
    const(char)* msg;
    void* state;
    void* zalloc;
    void* zfree;
    void* opaque;
    int data_type;
    ulong adler;
    ulong reserved;
}
static assert(z_stream.sizeof == 112, "z_stream layout changed");

private enum int Z_NO_FLUSH = 0;
private enum int Z_FINISH = 4;
private enum int Z_OK = 0;
private enum int Z_STREAM_END = 1;
private enum int Z_DEFLATED = 8;
private enum int Z_DEFAULT_STRATEGY = 0;

extern(C) {
    size_t BrotliEncoderMaxCompressedSize(size_t) nothrow @nogc;
    int BrotliEncoderCompress(int quality, int lgwin, int mode, size_t input_size,
                              const(ubyte)* input, size_t* encoded_size, ubyte* encoded) nothrow @nogc;
    int BrotliDecoderDecompress(size_t encoded_size, const(ubyte)* encoded,
                                size_t* decoded_size, ubyte* decoded) nothrow @nogc;
}

private enum int KIND_DEFLATE = 0;
private enum int KIND_INFLATE = 1;
private enum int KIND_GZIP = 2;
private enum int KIND_GUNZIP = 3;
private enum int KIND_RAW_DEFLATE = 4;
private enum int KIND_RAW_INFLATE = 5;

extern(C) {
    const(char)* zlibVersion() nothrow @nogc;
    int deflateInit2_(z_stream*, int level, int method, int windowBits,
                      int memLevel, int strategy, const(char)* ver,
                      int stream_size) nothrow @nogc;
    int deflate(z_stream*, int flush) nothrow @nogc;
    int deflateEnd(z_stream*) nothrow @nogc;
    int inflateInit2_(z_stream*, int windowBits, const(char)* ver,
                      int stream_size) nothrow @nogc;
    int inflate(z_stream*, int flush) nothrow @nogc;
    int inflateEnd(z_stream*) nothrow @nogc;
}

private enum int maxSlots = 32;
private enum int outChunk = 65536;
private enum size_t maxOutput = 256 * 1024 * 1024;

private struct Slot
{
    bool used;
    bool inflate;
    bool ended;
    uint id;
    Runtime* rt;
    z_stream zs;
}

private Slot[maxSlots] slots;
private uint nextId = 1;

private struct OutBuf
{
    ubyte* p;
    size_t len;
    size_t cap;
}

private bool outAppend(ref OutBuf b, const(ubyte)* src, size_t n) @nogc nothrow
{
    if (n == 0) return true;
    if (b.len + n > b.cap)
    {
        size_t cap = b.cap == 0 ? 4096 : b.cap;
        while (cap < b.len + n) cap *= 2;
        ubyte* p = cast(ubyte*) realloc(b.p, cap);
        if (p is null) return false;
        b.p = p;
        b.cap = cap;
    }
    memcpy(b.p + b.len, src, n);
    b.len += n;
    return true;
}

private Slot* findSlot(uint id) @nogc nothrow
{
    foreach (ref s; slots)
        if (s.used && s.id == id)
            return &s;
    return null;
}

private Slot* allocSlot(Runtime* rt, uint* id) @nogc nothrow
{
    foreach (ref s; slots)
    {
        if (s.used) continue;
        s.used = true;
        s.rt = rt;
        s.id = nextId++;
        if (nextId == 0) nextId = 1;
        *id = s.id;
        return &s;
    }
    return null;
}

private void freeSlot(Slot* s) @nogc nothrow
{
    if (s is null) return;
    if (s.inflate) inflateEnd(&s.zs);
    else deflateEnd(&s.zs);
    s.zs = z_stream.init;
    s.used = false;
    s.ended = false;
    s.id = 0;
    s.rt = null;
}

private void closeAllZ(Runtime* self) @nogc nothrow
{
    foreach (ref s; slots)
        if (s.used && s.rt is self)
            freeSlot(&s);
}

private JSValue zError(JSContext* ctx, Slot* s, const(char)* fallback) @nogc nothrow
{
    const(char)* msg = s.zs.msg !is null ? s.zs.msg : fallback;
    JSValue err = makeError(ctx, msg, "Z_DATA_ERROR", null, null);
    if (jsIsException(err)) return err;
    return throwError(ctx, err);
}

private extern(C) JSValue jsZlibCreateImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    int kind = 0, level = -1;
    if (argc < 1 || !toInt32(ctx, argv[0], &kind))
        return throwTypeError(ctx, "zlib.create requires a kind");
    if (argc >= 2) toInt32(ctx, argv[1], &level);
    if (level < -1) level = -1;
    if (level > 9) level = 9;
    if (kind < KIND_DEFLATE || kind > KIND_RAW_INFLATE)
        return throwRangeError(ctx, "invalid zlib kind");
    bool inflate = kind == KIND_INFLATE || kind == KIND_GUNZIP || kind == KIND_RAW_INFLATE;
    int windowBits = 15;
    if (kind == KIND_GZIP) windowBits = 15 + 16;
    else if (kind == KIND_GUNZIP) windowBits = 15 + 32;
    else if (kind == KIND_RAW_DEFLATE || kind == KIND_RAW_INFLATE) windowBits = -15;

    uint id = 0;
    Slot* s = allocSlot(runtimeOf(ctx), &id);
    if (s is null) return throwInternalError(ctx, "zlib table exhausted");
    s.inflate = inflate;
    int rc;
    if (inflate)
        rc = inflateInit2_(&s.zs, windowBits, zlibVersion(), z_stream.sizeof);
    else
        rc = deflateInit2_(&s.zs, level, Z_DEFLATED, windowBits, 8,
                           Z_DEFAULT_STRATEGY, zlibVersion(), z_stream.sizeof);
    if (rc != Z_OK)
    {
        s.used = false;
        return throwInternalError(ctx, "zlib init failed");
    }
    return jsInt(cast(int) id);
}
extern(C) JSValue jsZlibCreate(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsZlibCreateImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsZlibWriteImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "zlib.write requires (id, data)");
    Slot* s = findSlot(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid zlib handle");
    const(ubyte)* data = null;
    size_t len = 0;
    const(char)* cstr = null;
    JSValue holder = jsUndefined();
    if (jsIsString(argv[1]) && toStringView(ctx, argv[1], &cstr, &len))
    {
        data = cast(const(ubyte)*) cstr;
    }
    else
    {
        if (JS_IsArrayBuffer(argv[1]))
        {
            size_t size = 0;
            ubyte* p = JS_GetArrayBuffer(ctx, &size, argv[1]);
            if (p is null) return throwTypeError(ctx, "data must be bytes");
            data = p;
            len = size;
            holder = JS_DupValue(ctx, argv[1]);
        }
        else
        {
            size_t off = 0, n = 0, bpe = 0;
            JSValue ab = JS_GetTypedArrayBuffer(ctx, argv[1], &off, &n, &bpe);
            if (jsIsException(ab)) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "data must be bytes"); }
            size_t size = 0;
            ubyte* p = JS_GetArrayBuffer(ctx, &size, ab);
            if (p is null || off > size || n > size - off) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "data must be bytes"); }
            data = p + off;
            len = n;
            holder = ab;
        }
    }
    scope(exit) {
        if (cstr !is null) JS_FreeCString(ctx, cstr);
        if (!jsIsUndefined(holder)) JS_FreeValue(ctx, holder);
    }
    if (s.ended) return throwTypeError(ctx, "zlib stream already ended");

    OutBuf buf;
    scope(exit) free(buf.p);
    s.zs.next_in = data;
    s.zs.avail_in = cast(uint) len;
    int rc = Z_OK;
    while (true)
    {
        ubyte[outChunk] chunk = void;
        s.zs.next_out = chunk.ptr;
        s.zs.avail_out = outChunk;
        rc = s.inflate ? inflate(&s.zs, Z_NO_FLUSH) : deflate(&s.zs, Z_NO_FLUSH);
        size_t produced = outChunk - s.zs.avail_out;
        if (buf.len + produced > maxOutput)
        {
            freeSlot(s);
            return throwRangeError(ctx, "zlib output limit exceeded");
        }
        if (!outAppend(buf, chunk.ptr, produced))
        {
            freeSlot(s);
            return throwInternalError(ctx, "out of memory");
        }
        if (rc == Z_STREAM_END) { s.ended = true; break; }
        if (rc == -5 && s.zs.avail_in == 0 && produced == 0) break; // Z_BUF_ERROR, no progress
        if (rc != Z_OK) break;
        if (s.zs.avail_in == 0 && s.zs.avail_out != 0) break;
    }

    if (rc != Z_OK && rc != Z_STREAM_END)
    {
        JSValue err = zError(ctx, s, "zlib stream error");
        freeSlot(s);
        return err;
    }
    return JS_NewArrayBufferCopy(ctx, buf.p, buf.len);
}
extern(C) JSValue jsZlibWrite(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsZlibWriteImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsZlibEndImpl(JSContext* ctx, JSValueConst, int argc,
                                        JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "zlib.end requires an id");
    Slot* s = findSlot(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid zlib handle");

    OutBuf buf;
    scope(exit) free(buf.p);
    int rc = Z_OK;
    if (!s.inflate)
    {
        do
        {
            ubyte[outChunk] chunk = void;
            s.zs.next_in = null;
            s.zs.avail_in = 0;
            s.zs.next_out = chunk.ptr;
            s.zs.avail_out = outChunk;
            rc = deflate(&s.zs, Z_FINISH);
            size_t produced = outChunk - s.zs.avail_out;
            if (buf.len + produced > maxOutput)
            {
                freeSlot(s);
                return throwRangeError(ctx, "zlib output limit exceeded");
            }
            if (!outAppend(buf, chunk.ptr, produced))
            {
                freeSlot(s);
                return throwInternalError(ctx, "out of memory");
            }
        } while (rc == Z_OK);
        if (rc != Z_STREAM_END)
        {
            JSValue err = zError(ctx, s, "deflate finish failed");
            freeSlot(s);
            return err;
        }
    }
    else if (!s.ended)
    {
        // Node raises for truncated compressed input; an empty stream is an
        // error too, so do not silently return partial output.
        JSValue err = makeError(ctx, "unexpected end of file", "Z_BUF_ERROR", null, null);
        freeSlot(s);
        if (jsIsException(err)) return err;
        return throwError(ctx, err);
    }
    ubyte* p = buf.p;
    size_t n = buf.len;
    freeSlot(s);
    return JS_NewArrayBufferCopy(ctx, p, n);
}
extern(C) JSValue jsZlibEnd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsZlibEndImpl(ctx, thisVal, argc, argv); }

void zlibCloseAll(Runtime* self) @nogc nothrow
{
    closeAllZ(self);
}

private bool acquireBytes(JSContext* ctx, JSValueConst val, const(ubyte)** data,
                          size_t* len, JSValue* holder) @nogc nothrow
{
    *holder = jsUndefined();
    if (JS_IsArrayBuffer(val))
    {
        size_t size = 0;
        ubyte* p = JS_GetArrayBuffer(ctx, &size, val);
        if (p is null) return false;
        *data = p;
        *len = size;
        return true;
    }
    size_t off = 0, n = 0, bpe = 0;
    JSValue ab = JS_GetTypedArrayBuffer(ctx, val, &off, &n, &bpe);
    if (jsIsException(ab)) { JS_FreeValue(ctx, ab); return false; }
    size_t size = 0;
    ubyte* p = JS_GetArrayBuffer(ctx, &size, ab);
    if (p is null || off > size || n > size - off) { JS_FreeValue(ctx, ab); return false; }
    *data = p + off;
    *len = n;
    *holder = ab;
    return true;
}

private extern(C) JSValue jsBrotliCompressImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "brotliCompress(data, quality)");
    size_t len = 0;
    const(ubyte)* data = null;
    JSValue holder = jsUndefined();
    if (!acquireBytes(ctx, argv[0], &data, &len, &holder))
        return throwTypeError(ctx, "brotliCompress expects a Buffer");
    scope(exit) if (!jsIsUndefined(holder)) JS_FreeValue(ctx, holder);
    int quality = 5;
    if (argc > 1)
    {
        if (!toInt32(ctx, argv[1], &quality))
            return jsException();
        if (quality < 0) quality = 0;
        if (quality > 11) quality = 11;
    }
    size_t cap = BrotliEncoderMaxCompressedSize(len);
    ubyte* outBuf = cast(ubyte*) malloc(cap > 0 ? cap : 1);
    if (outBuf is null)
        return throwInternalError(ctx, "out of memory");
    scope(exit) free(outBuf);
    size_t outLen = cap;
    if (BrotliEncoderCompress(quality, 22, 0, len, data, &outLen, outBuf) != 1)
        return throwInternalError(ctx, "brotli compression failed");
    return JS_NewArrayBufferCopy(ctx, outBuf, outLen);
}

extern(C) JSValue jsBrotliCompress(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsBrotliCompressImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsBrotliDecompressImpl(JSContext* ctx, JSValueConst, int argc,
                                                 JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "brotliDecompress(data)");
    size_t len = 0;
    const(ubyte)* data = null;
    JSValue holder = jsUndefined();
    if (!acquireBytes(ctx, argv[0], &data, &len, &holder))
        return throwTypeError(ctx, "brotliDecompress expects a Buffer");
    scope(exit) if (!jsIsUndefined(holder)) JS_FreeValue(ctx, holder);
    size_t cap = len * 4 + 1024;
    for (int attempt = 0; attempt < 12; attempt++)
    {
        ubyte* outBuf = cast(ubyte*) malloc(cap > 0 ? cap : 1);
        if (outBuf is null)
            return throwInternalError(ctx, "out of memory");
        size_t outLen = cap;
        int r = BrotliDecoderDecompress(len, data, &outLen, outBuf);
        if (r == 1)
        {
            JSValue v = JS_NewArrayBufferCopy(ctx, outBuf, outLen);
            free(outBuf);
            return v;
        }
        free(outBuf);
        cap *= 2;
        if (cap > 256 * 1024 * 1024)
            break;
    }
    return throwInternalError(ctx, "brotli decompression failed");
}

extern(C) JSValue jsBrotliDecompress(JSContext* ctx, JSValueConst thisVal, int argc,
                                     JSValueConst* argv) nothrow @nogc
{
    return guarded!jsBrotliDecompressImpl(ctx, thisVal, argc, argv);
}

bool installZlib(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "create", &jsZlibCreate, 2)
        && addNativeFunction(ctx, obj, "write", &jsZlibWrite, 2)
        && addNativeFunction(ctx, obj, "end", &jsZlibEnd, 1)
        && addNativeFunction(ctx, obj, "brotliCompress", &jsBrotliCompress, 2)
        && addNativeFunction(ctx, obj, "brotliDecompress", &jsBrotliDecompress, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "zlib", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
