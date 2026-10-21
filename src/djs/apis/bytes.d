module djs.apis.bytes;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strlen;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.runtime : Runtime, guarded, newTrackedArrayBuffer, runtimeOf;

// Byte codecs for Buffer. The prelude owns the Buffer class; this module only
// converts between a JS string and bytes in either direction.

private const(char)* b64chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

private int hexVal(char c) @nogc nothrow
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private int b64Val(char c) @nogc nothrow
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62; // '-' is base64url
    if (c == '/' || c == '_') return 63; // '_' is base64url
    return -1;
}

// Decode one UTF-8 code point; advances i. Invalid bytes yield U+FFFD.
private uint utf8Next(const(char)* s, size_t len, size_t* i) @nogc nothrow
{
    ubyte b = cast(ubyte) s[*i];
    *i += 1;
    if (b < 0x80)
        return b;
    int extra = 0;
    uint cp = 0;
    if ((b & 0xE0) == 0xC0) { extra = 1; cp = b & 0x1F; }
    else if ((b & 0xF0) == 0xE0) { extra = 2; cp = b & 0x0F; }
    else if ((b & 0xF8) == 0xF0) { extra = 3; cp = b & 0x07; }
    else return 0xFFFD;
    for (int k = 0; k < extra; ++k)
    {
        if (*i >= len)
            return 0xFFFD;
        ubyte c = cast(ubyte) s[*i];
        if ((c & 0xC0) != 0x80)
            return 0xFFFD;
        *i += 1;
        cp = (cp << 6) | (c & 0x3F);
    }
    return cp;
}

private bool encodingIs(const(char)* enc, const(char)* name) @nogc nothrow
{
    if (enc is null)
        return false;
    size_t n = strlen(name);
    if (strlen(enc) != n)
        return false;
    for (size_t i = 0; i < n; ++i)
        if (enc[i] != name[i])
            return false;
    return true;
}

private extern(C) JSValue jsEncodeImpl(JSContext* ctx, JSValueConst, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    if (argc < 1 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "bytes.encode expects a string");
    const(char)* enc = null;
    if (argc >= 2 && !jsIsUndefined(argv[1]) && !jsIsNull(argv[1]))
    {
        if (!jsIsString(argv[1]))
            return throwTypeError(ctx, "encoding must be a string");
        size_t encLen = 0;
        enc = JS_ToCStringLen2(ctx, &encLen, argv[1], false);
        if (enc is null)
            return jsException();
    }

    size_t len = 0;
    const(char)* s = JS_ToCStringLen2(ctx, &len, argv[0], false);
    if (s is null)
    {
        if (enc !is null) JS_FreeCString(ctx, enc);
        return jsException();
    }

    ubyte* dstBytes = null;
    size_t outLen = 0;
    bool utf8 = enc is null || encodingIs(enc, "utf8") || encodingIs(enc, "utf-8");
    bool latin1 = encodingIs(enc, "latin1") || encodingIs(enc, "binary") ||
                  encodingIs(enc, "ascii");
    bool hex = encodingIs(enc, "hex");
    bool b64 = encodingIs(enc, "base64");

    if (utf8)
    {
        dstBytes = cast(ubyte*) malloc(len > 0 ? len : 1);
        if (dstBytes !is null)
        {
            memcpy(dstBytes, s, len);
            outLen = len;
            // QuickJS encodes unpaired surrogates as CESU-8 (ED A0..BF xx).
            // Node replaces them with U+FFFD; rewrite in place, same length.
            for (size_t i = 0; i + 2 < outLen; ++i)
            {
                if (dstBytes[i] == 0xED &&
                    dstBytes[i + 1] >= 0xA0 && dstBytes[i + 1] <= 0xBF)
                {
                    dstBytes[i] = 0xEF;
                    dstBytes[i + 1] = 0xBF;
                    dstBytes[i + 2] = 0xBD;
                    i += 2;
                }
            }
        }
    }
    else if (latin1 || hex || b64)
    {
        if (latin1)
        {
            dstBytes = cast(ubyte*) malloc(len > 0 ? len : 1);
            size_t i = 0, o = 0;
            while (i < len)
            {
                uint cp = utf8Next(s, len, &i);
                if (dstBytes is null) break;
                dstBytes[o++] = cast(ubyte) (cp & 0xFF);
            }
            outLen = o;
        }
        else if (hex)
        {
            dstBytes = cast(ubyte*) malloc(len / 2 + 1);
            size_t o = 0;
            for (size_t i = 0; dstBytes !is null && i + 1 < len; i += 2)
            {
                int hi = hexVal(s[i]);
                int lo = hexVal(s[i + 1]);
                if (hi < 0 || lo < 0)
                    break;
                dstBytes[o++] = cast(ubyte) ((hi << 4) | lo);
            }
            outLen = o;
        }
        else
        {
            dstBytes = cast(ubyte*) malloc(len / 4 * 3 + 3);
            size_t o = 0;
            int acc = 0, bits = 0;
            for (size_t i = 0; dstBytes !is null && i < len; ++i)
            {
                char c = s[i];
                if (c == '=')
                    break;
                int v = b64Val(c);
                if (v < 0)
                    continue; // whitespace and junk are ignored, like Node
                acc = (acc << 6) | v;
                bits += 6;
                if (bits >= 8)
                {
                    bits -= 8;
                    dstBytes[o++] = cast(ubyte) ((acc >> bits) & 0xFF);
                }
            }
            outLen = o;
        }
    }
    else
    {
        JS_FreeCString(ctx, s);
        if (enc !is null) JS_FreeCString(ctx, enc);
        return throwTypeError(ctx, "unknown encoding");
    }

    JS_FreeCString(ctx, s);
    if (enc !is null) JS_FreeCString(ctx, enc);
    if (dstBytes is null)
        return throwInternalError(ctx, "dstBytes of memory");
    JSValue ab = newTrackedArrayBuffer(ctx, runtimeOf(ctx), dstBytes, outLen);
    free(dstBytes);
    return ab;
}

private extern(C) JSValue jsEncode(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsEncodeImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsDecodeImpl(JSContext* ctx, JSValueConst, int argc,
                                      JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return throwTypeError(ctx, "bytes.decode expects a view");
    size_t len = 0;
    ubyte* bytes = JS_GetUint8Array(ctx, &len, argv[0]);
    if (bytes is null)
    {
        if (JS_HasException(ctx))
        {
            JSValue e = JS_GetException(ctx);
            JS_FreeValue(ctx, e);
        }
        return throwTypeError(ctx, "bytes.decode expects a Uint8Array");
    }

    const(char)* enc = null;
    if (argc >= 2 && !jsIsUndefined(argv[1]) && !jsIsNull(argv[1]))
    {
        if (!jsIsString(argv[1]))
            return throwTypeError(ctx, "encoding must be a string");
        size_t encLen = 0;
        enc = JS_ToCStringLen2(ctx, &encLen, argv[1], false);
        if (enc is null)
            return jsException();
    }

    bool utf8 = enc is null || encodingIs(enc, "utf8") || encodingIs(enc, "utf-8");
    JSValue result;
    if (utf8)
    {
        result = JS_NewStringLen(ctx, cast(const(char)*) bytes, len);
    }
    else
    {
        char* dstBytes = null;
        size_t outLen = 0;
        bool latin1 = encodingIs(enc, "latin1") || encodingIs(enc, "binary") ||
                      encodingIs(enc, "ascii");
        bool ascii = encodingIs(enc, "ascii");
        bool hex = encodingIs(enc, "hex");
        bool b64 = encodingIs(enc, "base64");
        if (latin1)
        {
            dstBytes = cast(char*) malloc(len * 2 + 1);
            size_t o = 0;
            for (size_t i = 0; dstBytes !is null && i < len; ++i)
            {
                ubyte b = bytes[i];
                if (ascii) b &= 0x7F;
                if (b < 0x80)
                    dstBytes[o++] = cast(char) b;
                else
                {
                    dstBytes[o++] = cast(char) (0xC0 | (b >> 6));
                    dstBytes[o++] = cast(char) (0x80 | (b & 0x3F));
                }
            }
            outLen = o;
        }
        else if (hex)
        {
            dstBytes = cast(char*) malloc(len * 2 + 1);
            static const(char)* digits = "0123456789abcdef";
            for (size_t i = 0; dstBytes !is null && i < len; ++i)
            {
                dstBytes[i * 2] = digits[bytes[i] >> 4];
                dstBytes[i * 2 + 1] = digits[bytes[i] & 0x0F];
            }
            outLen = len * 2;
        }
        else if (b64)
        {
            size_t groups = (len + 2) / 3;
            dstBytes = cast(char*) malloc(groups * 4 + 1);
            size_t o = 0;
            for (size_t i = 0; dstBytes !is null && i < len; i += 3)
            {
                uint v = cast(uint) bytes[i] << 16;
                if (i + 1 < len) v |= cast(uint) bytes[i + 1] << 8;
                if (i + 2 < len) v |= bytes[i + 2];
                dstBytes[o++] = b64chars[(v >> 18) & 0x3F];
                dstBytes[o++] = b64chars[(v >> 12) & 0x3F];
                dstBytes[o++] = i + 1 < len ? b64chars[(v >> 6) & 0x3F] : '=';
                dstBytes[o++] = i + 2 < len ? b64chars[v & 0x3F] : '=';
            }
            outLen = o;
        }
        else
        {
            if (enc !is null) JS_FreeCString(ctx, enc);
            return throwTypeError(ctx, "unknown encoding");
        }
        if (enc !is null) JS_FreeCString(ctx, enc);
        if (dstBytes is null)
            return throwInternalError(ctx, "dstBytes of memory");
        result = JS_NewStringLen(ctx, dstBytes, outLen);
        free(dstBytes);
        return result;
    }
    if (enc !is null) JS_FreeCString(ctx, enc);
    return result;
}

private extern(C) JSValue jsDecode(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsDecodeImpl(ctx, thisVal, argc, argv);
}

bool installBytes(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "encode", &jsEncode, 2)
        && addNativeFunction(ctx, obj, "decode", &jsDecode, 2);
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "bytes", obj) > 0;
}
