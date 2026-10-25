module djs.modules.json;

// A small malloc-backed JSON reader for package metadata. It exists because
// package resolution is @nogc and the prelude/QuickJS heap must not be used
// during module loading. Only what package.json needs is modelled: objects,
// arrays, strings, numbers, booleans and null. Malformed input yields null.

import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy, strlen;

enum JsonKind : ubyte
{
    nullValue,
    boolValue,
    numberValue,
    stringValue,
    arrayValue,
    objectValue,
}

struct JsonValue
{
    JsonKind kind;
    bool boolean;
    char* string;      // stringValue (NUL-terminated)
    JsonValue** items; // arrayValue
    char** keys;       // objectValue
    size_t count;
    size_t capacity;
}

private struct Parser
{
    const(char)* s;
    size_t len;
    size_t i;
    int depth;
    bool ok;
}

private bool skipWs(Parser* p) @nogc nothrow
{
    while (p.i < p.len)
    {
        char c = p.s[p.i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
            p.i += 1;
        else
            break;
    }
    return p.i < p.len;
}

private int hexDigit(char c) pure @safe @nogc nothrow
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private bool parseHexAt(const(char)* s, size_t pos, size_t limit, uint* dst) @nogc nothrow
{
    if (pos + 4 > limit)
        return false;
    uint v = 0;
    for (int k = 0; k < 4; ++k)
    {
        int d = hexDigit(s[pos + k]);
        if (d < 0)
            return false;
        v = (v << 4) | cast(uint) d;
    }
    *dst = v;
    return true;
}

private void appendUtf8(char* dst, size_t* o, uint cp) @nogc nothrow
{
    if (cp < 0x80)
        dst[(*o)++] = cast(char) cp;
    else if (cp < 0x800)
    {
        dst[(*o)++] = cast(char) (0xC0 | (cp >> 6));
        dst[(*o)++] = cast(char) (0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        dst[(*o)++] = cast(char) (0xE0 | (cp >> 12));
        dst[(*o)++] = cast(char) (0x80 | ((cp >> 6) & 0x3F));
        dst[(*o)++] = cast(char) (0x80 | (cp & 0x3F));
    }
    else
    {
        dst[(*o)++] = cast(char) (0xF0 | (cp >> 18));
        dst[(*o)++] = cast(char) (0x80 | ((cp >> 12) & 0x3F));
        dst[(*o)++] = cast(char) (0x80 | ((cp >> 6) & 0x3F));
        dst[(*o)++] = cast(char) (0x80 | (cp & 0x3F));
    }
}

// Decode the body of a JSON string literal (between the quotes), applying
// escape sequences. Returns a malloc'd NUL-terminated string, or null for
// malformed input (bad \u escape). Shared by the parser and by
// packageJsonValue so every reader decodes escapes the same way.
char* jsonDecodeString(const(char)* s, size_t start, size_t end) @nogc nothrow
{
    if (end < start)
        return null;
    // Worst case: every remaining char is part of a surrogate-pair escape
    // expanding to 4 UTF-8 bytes; 1 byte in never costs more than 4 out.
    char* dst = cast(char*) malloc((end - start) * 4 + 1);
    if (dst is null)
        return null;
    size_t o = 0;
    size_t i = start;
    while (i < end)
    {
        char c = s[i++];
        if (c != '\\')
        {
            dst[o++] = c;
            continue;
        }
        if (i >= end)
        {
            free(dst);
            return null;
        }
        char e = s[i++];
        switch (e)
        {
        case '"': dst[o++] = '"'; break;
        case '\\': dst[o++] = '\\'; break;
        case '/': dst[o++] = '/'; break;
        case 'b': dst[o++] = '\b'; break;
        case 'f': dst[o++] = '\f'; break;
        case 'n': dst[o++] = '\n'; break;
        case 'r': dst[o++] = '\r'; break;
        case 't': dst[o++] = '\t'; break;
        case 'u':
        {
            uint cp = 0;
            if (!parseHexAt(s, i, end, &cp))
            {
                free(dst);
                return null;
            }
            i += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 5 < end &&
                s[i] == '\\' && s[i + 1] == 'u')
            {
                uint lo = 0;
                if (parseHexAt(s, i + 2, end, &lo) && lo >= 0xDC00 && lo <= 0xDFFF)
                {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
            }
            appendUtf8(dst, &o, cp);
            break;
        }
        default:
            dst[o++] = e;
            break;
        }
    }
    dst[o] = 0;
    return dst;
}

private char* parseString(Parser* p) @nogc nothrow
{
    if (p.i >= p.len || p.s[p.i] != '"')
        return null;
    p.i += 1;
    size_t start = p.i;
    while (p.i < p.len)
    {
        char c = p.s[p.i];
        if (c == '"')
            break;
        if (c == '\\')
            p.i += 2; // skip the escaped character; \" must not end the scan
        else
            p.i += 1;
    }
    if (p.i >= p.len || p.s[p.i] != '"')
        return null;
    char* decoded = jsonDecodeString(p.s, start, p.i);
    if (decoded is null)
    {
        p.ok = false;
        return null;
    }
    p.i += 1; // closing quote
    return decoded;
}

private JsonValue* parseValue(Parser* p) @nogc nothrow;

private void freeValue(JsonValue* v) @nogc nothrow
{
    if (v is null)
        return;
    if (v.string !is null)
        free(v.string);
    if (v.items !is null)
    {
        for (size_t i = 0; i < v.count; ++i)
            freeValue(v.items[i]);
        free(v.items);
    }
    if (v.keys !is null)
    {
        for (size_t i = 0; i < v.count; ++i)
            free(v.keys[i]);
        free(v.keys);
    }
    free(v);
}

private bool pushItem(JsonValue* v, JsonValue* item) @nogc nothrow
{
    if (v.count == v.capacity)
    {
        size_t next = v.capacity == 0 ? 4 : v.capacity * 2;
        JsonValue** grown = cast(JsonValue**) realloc(v.items, next * (JsonValue*).sizeof);
        if (grown is null)
            return false;
        v.items = grown;
        v.capacity = next;
    }
    v.items[v.count++] = item;
    return true;
}

private bool pushKey(JsonValue* v, char* key) @nogc nothrow
{
    if (v.count == v.capacity)
    {
        size_t next = v.capacity == 0 ? 4 : v.capacity * 2;
        char** gk = cast(char**) realloc(v.keys, next * (char*).sizeof);
        if (gk is null)
            return false;
        v.keys = gk;
        JsonValue** gi = cast(JsonValue**) realloc(v.items, next * (JsonValue*).sizeof);
        if (gi is null)
            return false;
        v.items = gi;
        v.capacity = next;
    }
    v.keys[v.count] = key;
    v.items[v.count] = null;
    v.count += 1;
    return true;
}

private bool parseLiteral(Parser* p, const(char)* lit) @nogc nothrow
{
    size_t n = strlen(lit);
    if (p.i + n > p.len)
        return false;
    for (size_t k = 0; k < n; ++k)
        if (p.s[p.i + k] != lit[k])
            return false;
    p.i += n;
    return true;
}

private JsonValue* parseValue(Parser* p) @nogc nothrow
{
    if (!p.ok || p.depth > 64 || !skipWs(p))
    {
        p.ok = false;
        return null;
    }
    char c = p.s[p.i];
    JsonValue* v = cast(JsonValue*) malloc(JsonValue.sizeof);
    if (v is null)
    {
        p.ok = false;
        return null;
    }
    *v = JsonValue.init;

    if (c == '"')
    {
        v.kind = JsonKind.stringValue;
        v.string = parseString(p);
        if (v.string is null)
        {
            p.ok = false;
            free(v);
            return null;
        }
        return v;
    }
    if (c == '{')
    {
        v.kind = JsonKind.objectValue;
        p.i += 1;
        p.depth += 1;
        if (!skipWs(p))
        {
            p.ok = false;
            free(v);
            return null;
        }
        if (p.i < p.len && p.s[p.i] == '}')
        {
            p.i += 1;
            p.depth -= 1;
            return v;
        }
        for (;;)
        {
            if (!skipWs(p) || p.s[p.i] != '"')
            {
                p.ok = false;
                break;
            }
            char* key = parseString(p);
            if (key is null)
            {
                p.ok = false;
                break;
            }
            if (!skipWs(p) || p.s[p.i] != ':')
            {
                free(key);
                p.ok = false;
                break;
            }
            p.i += 1;
            JsonValue* item = parseValue(p);
            if (item is null)
            {
                free(key);
                p.ok = false;
                break;
            }
            if (!pushKey(v, key))
            {
                free(key);
                freeValue(item);
                p.ok = false;
                break;
            }
            v.items[v.count - 1] = item;
            if (!skipWs(p))
            {
                p.ok = false;
                break;
            }
            if (p.s[p.i] == ',')
            {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}')
            {
                p.i += 1;
                p.depth -= 1;
                return v;
            }
            p.ok = false;
            break;
        }
        freeValue(v);
        return null;
    }
    if (c == '[')
    {
        v.kind = JsonKind.arrayValue;
        p.i += 1;
        p.depth += 1;
        if (!skipWs(p))
        {
            p.ok = false;
            free(v);
            return null;
        }
        if (p.i < p.len && p.s[p.i] == ']')
        {
            p.i += 1;
            p.depth -= 1;
            return v;
        }
        for (;;)
        {
            JsonValue* item = parseValue(p);
            if (item is null || !pushItem(v, item))
            {
                freeValue(item);
                p.ok = false;
                break;
            }
            if (!skipWs(p))
            {
                p.ok = false;
                break;
            }
            if (p.s[p.i] == ',')
            {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']')
            {
                p.i += 1;
                p.depth -= 1;
                return v;
            }
            p.ok = false;
            break;
        }
        freeValue(v);
        return null;
    }
    if (c == 't' && parseLiteral(p, "true"))
    {
        v.kind = JsonKind.boolValue;
        v.boolean = true;
        return v;
    }
    if (c == 'f' && parseLiteral(p, "false"))
    {
        v.kind = JsonKind.boolValue;
        v.boolean = false;
        return v;
    }
    if (c == 'n' && parseLiteral(p, "null"))
    {
        v.kind = JsonKind.nullValue;
        return v;
    }
    if (c == '-' || (c >= '0' && c <= '9'))
    {
        v.kind = JsonKind.numberValue;
        // The numeric value is not needed; validate the shape loosely.
        while (p.i < p.len)
        {
            char d = p.s[p.i];
            if ((d >= '0' && d <= '9') || d == '-' || d == '+' || d == '.' ||
                d == 'e' || d == 'E')
                p.i += 1;
            else
                break;
        }
        return v;
    }
    p.ok = false;
    free(v);
    return null;
}

JsonValue* jsonParse(const(char)* src, size_t len) @nogc nothrow
{
    if (src is null)
        return null;
    Parser p;
    p.s = src;
    p.len = len;
    p.i = 0;
    p.depth = 0;
    p.ok = true;
    JsonValue* v = parseValue(&p);
    if (!p.ok)
    {
        freeValue(v);
        return null;
    }
    // Trailing whitespace is fine; anything else means the document is
    // malformed, and Node's JSON.parse rejects it rather than reading a prefix.
    while (p.i < p.len)
    {
        char c = p.s[p.i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        {
            p.i += 1;
            continue;
        }
        freeValue(v);
        return null;
    }
    return v;
}

void jsonFree(JsonValue* v) @nogc nothrow
{
    freeValue(v);
}

JsonValue* jsonGet(JsonValue* obj, const(char)* key) @nogc nothrow
{
    if (obj is null || obj.kind != JsonKind.objectValue || key is null)
        return null;
    for (size_t i = 0; i < obj.count; ++i)
        if (obj.keys[i] !is null && strcmpZ(obj.keys[i], key))
            return obj.items[i];
    return null;
}

private bool strcmpZ(const(char)* a, const(char)* b) pure @trusted @nogc nothrow
{
    if (a is null || b is null)
        return false;
    size_t i = 0;
    while (a[i] != 0 && a[i] == b[i])
        i += 1;
    return a[i] == 0 && b[i] == 0;
}

unittest
{
    import core.stdc.string : memcmp;

    // Structure: objects, arrays, numbers, booleans, null.
    static immutable char[] doc =
        `{"name":"x","n":2,"ok":true,"nil":null,"arr":[1,"two"],"o":{"k":"v"}}`;
    JsonValue* root = jsonParse(doc.ptr, doc.length);
    assert(root !is null && root.kind == JsonKind.objectValue);
    assert(jsonGet(root, "name").kind == JsonKind.stringValue);
    assert(jsonGet(root, "n").kind == JsonKind.numberValue);
    assert(jsonGet(root, "ok").kind == JsonKind.boolValue && jsonGet(root, "ok").boolean);
    assert(jsonGet(root, "nil").kind == JsonKind.nullValue);
    JsonValue* arr = jsonGet(root, "arr");
    assert(arr.kind == JsonKind.arrayValue && arr.count == 2);
    assert(jsonGet(jsonGet(root, "o"), "k").kind == JsonKind.stringValue);
    assert(jsonGet(root, "missing") is null);
    jsonFree(root);

    // Escapes, including the solidus and the two-character controls.
    static immutable char[] esc = `"a\"b\\c\/d\be\ff\ng\rh\ti"`;
    JsonValue* ev = jsonParse(esc.ptr, esc.length);
    assert(ev !is null && ev.kind == JsonKind.stringValue);
    static immutable char[] escWant = "a\"b\\c/d\be\ff\ng\rh\ti";
    assert(strlen(ev.string) == escWant.length);
    assert(memcmp(ev.string, escWant.ptr, escWant.length) == 0);
    jsonFree(ev);

    // \u escapes become UTF-8; a surrogate pair becomes one four-byte code point.
    static immutable char[] uni = `"\u00e9\u20ac\ud83d\ude00"`;
    JsonValue* uv = jsonParse(uni.ptr, uni.length);
    assert(uv !is null);
    static immutable ubyte[] uniWant = [
        0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80];
    assert(strlen(uv.string) == uniWant.length);
    assert(memcmp(uv.string, uniWant.ptr, uniWant.length) == 0);
    jsonFree(uv);

    // Malformed input is rejected, not half-read.
    static immutable char[] bad = `{"a":`;
    assert(jsonParse(bad.ptr, bad.length) is null);
    static immutable char[] trailing = `{"a":1}x`;
    assert(jsonParse(trailing.ptr, trailing.length) is null);
    static immutable char[] ws = "{\"a\":1} \n";
    JsonValue* wv = jsonParse(ws.ptr, ws.length);
    assert(wv !is null);
    jsonFree(wv);
}
