module djs.modules.cjsnames;

// Heuristic CJS named-export detection, modelled on Node's cjs-module-lexer
// for the common patterns. It only proposes names; the ESM facade reads
// `__m.name`, so a missed name costs a syntax error and a false positive
// yields undefined rather than executing anything.
//
// Structure: the scanner is `@safe` slice code driven by a `ref NameSet`.
// Everything that touches a C string, the allocator or the open-addressed
// index's raw storage is a small `@trusted` helper with a stated invariant, so
// the token logic itself gets bounds checks in release builds.

import core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memcpy, strlen;

struct NameSet
{
    // Slices rather than bare pointers: indexing them is `@safe` and checked.
    char*[] names;
    size_t count;
    size_t capacity;
    // Open-addressed index over `names`. A slot stores 1 + the index into
    // `names`, with 0 meaning empty; the hash is kept alongside so a probe
    // rejects a collision without touching the string.
    Slot[] slots;
    size_t slotCount;
}

private struct Slot
{
    size_t hash;
    size_t index;
}

private bool isStart(char c) pure @safe @nogc nothrow
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}

private bool isPart(char c) pure @safe @nogc nothrow
{
    return isStart(c) || isDigit(c);
}

private bool isDigit(char c) pure @safe @nogc nothrow
{
    return c >= '0' && c <= '9';
}

// ---------------------------------------------------------------------------
// The @trusted layer. Each helper below is the only place a raw pointer or the
// C allocator is touched; the invariant is stated at the call site.
// ---------------------------------------------------------------------------

// `known` is a NUL-terminated copy made by allocName; compare it to `name`
// without trusting `name` for anything past its length.
private @trusted bool sameName(const(char)* known, const(char)[] name) @nogc nothrow
{
    foreach (i; 0 .. name.length)
        if (known[i] != name[i])
            return false;
    return known[name.length] == 0;
}

private @trusted const(char)[] storedName(const(char)* p) @nogc nothrow
{
    return p[0 .. strlen(p)];
}

private @trusted char* allocName(const(char)[] name) @nogc nothrow
{
    char* p = cast(char*) malloc(name.length + 1);
    if (p is null)
        return null;
    memcpy(p, name.ptr, name.length);
    p[name.length] = 0;
    return p;
}

private @trusted bool growNames(ref NameSet set) @nogc nothrow
{
    size_t next = set.capacity == 0 ? 8 : set.capacity * 2;
    char** grown = cast(char**) realloc(set.names.ptr, next * (char*).sizeof);
    if (grown is null)
        return false;
    set.names = grown[0 .. next];
    set.capacity = next;
    return true;
}

private @trusted Slot[] allocSlots(size_t n) @nogc nothrow
{
    Slot* p = cast(Slot*) calloc(n, Slot.sizeof);
    return p is null ? null : p[0 .. n];
}

private @trusted void releaseSlots(Slot[] slots) @nogc nothrow
{
    free(slots.ptr);
}

// ---------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------

private bool reserved(const(char)[] name) pure @safe @nogc nothrow
{
    static immutable string[] words = [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "function", "if", "import", "in", "instanceof", "new",
        "null", "return", "super", "switch", "this", "throw", "true", "try",
        "typeof", "var", "void", "while", "with", "yield", "let", "static",
        "await", "implements", "interface", "package", "private", "protected",
        "public",
    ];
    foreach (w; words)
        if (w == name)
            return true;
    return false;
}

private size_t fnv1a(const(char)[] s) pure @safe @nogc nothrow
{
    size_t h = 0xcbf29ce484222325UL;
    foreach (c; s)
    {
        h ^= cast(ubyte) c;
        h *= 0x100000001b3UL;
    }
    return h;
}

private size_t slotCapacityFor(size_t names) pure @safe @nogc nothrow
{
    size_t cap = 64;
    while (cap < names * 2)
        cap *= 2;
    return cap;
}

// Rebuild the index; every entry is re-probed against the larger table.
private bool rehashSlots(ref NameSet set, size_t newCount) @safe @nogc nothrow
{
    Slot[] slots = allocSlots(newCount);
    if (slots.length == 0)
        return false;
    foreach (i; 0 .. set.count)
    {
        const(char)[] name = storedName(set.names[i]);
        size_t h = fnv1a(name);
        size_t pos = h & (newCount - 1);
        while (slots[pos].index != 0)
            pos = (pos + 1) & (newCount - 1);
        slots[pos].hash = h;
        slots[pos].index = i + 1;
    }
    releaseSlots(set.slots);
    set.slots = slots;
    set.slotCount = newCount;
    return true;
}

// Scan the member of an `exports.` / `exports[...]` assignment: an
// identifier (`exports.foo = 1`) or a quoted string key
// (`exports['foo-bar'] = 1`, matching cjs-module-lexer), followed by a
// plain assignment (a `==` comparison contributes nothing). `bracket`
// selects the `[`quoted`]` form. `j` advances past the member either way.
private void addAssignmentName(const(char)[] s, ref size_t j, bool bracket,
                               ref NameSet set)
    @safe @nogc nothrow
{
    size_t start = j;
    size_t n = 0;
    if (bracket)
    {
        if (j >= s.length || (s[j] != '"' && s[j] != '\''))
            return;
        size_t e = skipString(s, j);
        start = j + 1;
        n = e > start ? e - start - 1 : 0;
        j = e;
        if (j >= s.length || s[j] != ']')
            return;
        j += 1;
    }
    else
    {
        while (j < s.length && isPart(s[j]))
            j += 1;
        n = j - start;
    }
    if (n == 0 || j >= s.length)
        return;
    size_t k = j;
    while (k < s.length && (s[k] == ' ' || s[k] == '\t'))
        k += 1;
    if (k < s.length && s[k] == '=' && (k + 1 >= s.length || s[k + 1] != '='))
        addName(set, s[start .. start + n]);
}

private void addName(ref NameSet set, const(char)[] name) @safe @nogc nothrow{
    if (name.length == 0 || !isStart(name[0]) || reserved(name))
        return;
    // Keep the table at most half full so probe runs stay short.
    if (set.slotCount == 0 || (set.count + 1) * 2 > set.slotCount)
    {
        size_t target = set.slotCount == 0 ? slotCapacityFor(1)
                                           : slotCapacityFor(set.count + 1);
        if (target > set.slotCount && !rehashSlots(set, target))
            return;
    }
    size_t h = fnv1a(name);
    size_t pos = h & (set.slotCount - 1);
    while (set.slots[pos].index != 0)
    {
        if (set.slots[pos].hash == h &&
            sameName(set.names[set.slots[pos].index - 1], name))
            return;
        pos = (pos + 1) & (set.slotCount - 1);
    }
    if (set.count == set.capacity && !growNames(set))
        return;
    char* copy = allocName(name);
    if (copy is null)
        return;
    set.names[set.count] = copy;
    set.slots[pos].hash = h;
    set.slots[pos].index = set.count + 1;
    set.count += 1;
}

void nameSetFree(ref NameSet set) @trusted @nogc nothrow
{
    foreach (i; 0 .. set.count)
        free(set.names[i]);
    free(set.names.ptr);
    free(set.slots.ptr);
    set = NameSet.init;
}

// Public boundary: callers hold a NameSet by pointer for historical reasons.
void nameSetFree(NameSet* set) @trusted @nogc nothrow
{
    if (set !is null)
        nameSetFree(*set);
}

// ---------------------------------------------------------------------------
// Tokenizer.
// ---------------------------------------------------------------------------

private bool startsWith(const(char)[] s, size_t at, const(char)[] lit) pure @safe @nogc nothrow
{
    return at + lit.length <= s.length && s[at .. at + lit.length] == lit;
}

// Skip a quoted string starting at s[i]; returns the index after the closing
// quote (or s.length when the string is unterminated).
private size_t skipString(const(char)[] s, size_t i) pure @safe @nogc nothrow
{
    char q = s[i];
    i += 1;
    while (i < s.length)
    {
        if (s[i] == '\\')
            i += 2;
        else if (s[i] == q)
            return i + 1;
        else
            i += 1;
    }
    return i;
}

// Keywords after which an expression, and therefore a regex literal, may
// start. Everything else ending in an identifier is a value, so `/` after it
// is division.
private bool isExprKeyword(const(char)[] id) pure @safe @nogc nothrow
{
    static immutable string[] words = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
        "do", "else", "case", "yield", "await", "throw",
    ];
    foreach (w; words)
        if (w == id)
            return true;
    return false;
}

// Skip a regex literal at s[i] == '/'. Returns the index after the closing
// slash and any flags, or 0 when there is no closing slash on the line.
// Regex literals cannot contain a raw newline, so bailing there keeps a
// misread division (or an ambiguous `}`) from swallowing the rest of the file;
// the caller then treats the character as an ordinary operator.
private size_t skipRegex(const(char)[] s, size_t i) pure @safe @nogc nothrow
{
    size_t j = i + 1;
    bool inClass = false;
    while (j < s.length)
    {
        char c = s[j];
        if (c == '\\')
        {
            j += 2;
            continue;
        }
        if (c == '\n')
            return 0;
        if (inClass)
        {
            if (c == ']')
                inClass = false;
            j += 1;
            continue;
        }
        if (c == '[')
        {
            inClass = true;
            j += 1;
            continue;
        }
        if (c == '/')
        {
            j += 1;
            while (j < s.length && ((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z')))
                j += 1;
            return j;
        }
        j += 1;
    }
    return 0;
}

// True when the previous non-space character opens the object or separates
// properties, i.e. the string at `j` is in key position, not value position.
private bool atPropertyStart(const(char)[] s, size_t j) pure @safe @nogc nothrow
{
    while (j > 0)
    {
        j -= 1;
        char c = s[j];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
            continue;
        return c == '{' || c == ',';
    }
    return false;
}

private void scanNames(const(char)[] s, ref NameSet set) @safe @nogc nothrow
{
    enum Tok
    {
        none,
        ident,
        number,
        value,
        punct,
    }
    Tok prev = Tok.none;
    char prevPunct = 0;
    size_t lastIdent = 0;
    size_t lastIdentLen = 0;
    size_t i = 0;
    while (i < s.length)
    {
        char c = s[i];
        // Whitespace must not disturb the previous-token state: `|| /re/` and
        // `||/re/` are the same, and resetting to a blank "punctuation" would
        // make the slash look like division.
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        {
            i += 1;
            continue;
        }
        if (c == '/' && i + 1 < s.length && s[i + 1] == '/')
        {
            i += 2;
            while (i < s.length && s[i] != '\n')
                i += 1;
            continue;
        }
        if (c == '/' && i + 1 < s.length && s[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/'))
                i += 1;
            i += 2;
            continue;
        }
        if (c == '\'' || c == '"' || c == '`')
        {
            i = skipString(s, i);
            prev = Tok.value;
            continue;
        }
        if (c == '/')
        {
            bool regexOk;
            final switch (prev)
            {
            case Tok.none:
                regexOk = true;
                break;
            case Tok.ident:
                regexOk = isExprKeyword(s[lastIdent .. lastIdent + lastIdentLen]);
                break;
            case Tok.number:
            case Tok.value:
                regexOk = false;
                break;
            case Tok.punct:
                // An expression may follow an opening bracket, a separator, an
                // assignment or a unary/binary operator. `)` and `]` end an
                // expression, so `/` after them is division; `}` is ambiguous
                // and is treated as allowing a regex because skipping a
                // division is harmless (skipRegex bails at the newline) while
                // scanning a regex body as code is not.
                regexOk = prevPunct == '(' || prevPunct == '[' || prevPunct == '{' ||
                    prevPunct == '}' || prevPunct == ',' || prevPunct == ';' ||
                    prevPunct == ':' || prevPunct == '=' || prevPunct == '!' ||
                    prevPunct == '?' || prevPunct == '&' || prevPunct == '|' ||
                    prevPunct == '+' || prevPunct == '-' || prevPunct == '*' ||
                    prevPunct == '%' || prevPunct == '^' || prevPunct == '~';
                break;
            }
            if (regexOk)
            {
                size_t j = skipRegex(s, i);
                if (j != 0)
                {
                    i = j;
                    prev = Tok.value;
                    continue;
                }
            }
            prev = Tok.punct;
            prevPunct = '/';
            i += 1;
            continue;
        }
        if (startsWith(s, i, "exports."))
        {
            size_t j = i + 8;
            addAssignmentName(s, j, false, set);
            i = j;
            continue;
        }
        // exports['quoted-key'] = ... — and module.exports['...'], which
        // reaches this same branch at its `exports` tail.
        if (startsWith(s, i, "exports["))
        {
            size_t j = i + 8;
            addAssignmentName(s, j, true, set);
            i = j;
            continue;
        }
        if (startsWith(s, i, "module.exports"))
        {
            // "module.exports" is 14 characters; the member form
            // (`module.exports.x = ...`) delegates to the shared assignment
            // scanner, the whole-object form (`module.exports = {...}`) to
            // the literal scanner below.
            size_t j = i + 14;
            while (j < s.length && (s[j] == ' ' || s[j] == '\t'))
                j += 1;
            if (j < s.length && s[j] == '.')
            {
                j += 1;
                addAssignmentName(s, j, false, set);
                i = j;
                continue;
            }
            if (j < s.length && s[j] == '[')
            {
                j += 1;
                addAssignmentName(s, j, true, set);
                i = j;
                continue;
            }
            if (j < s.length && s[j] == '=')
            {
                j += 1;
                while (j < s.length && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n'))
                    j += 1;
                if (j < s.length && s[j] == '{')
                {
                    // Collect top-level shorthand/`key:` properties.
                    j += 1;
                    int depth = 1;
                    while (j < s.length && depth > 0)
                    {
                        char d = s[j];
                        if (d == '"' || d == '\'')
                        {
                            // A quoted *key* (`{ "e": 4 }`) is a name; a quoted
                            // value is not. Position decides.
                            size_t e = skipString(s, j);
                            if (depth == 1 && atPropertyStart(s, j))
                            {
                                size_t k = e;
                                while (k < s.length && (s[k] == ' ' || s[k] == '\t' || s[k] == '\n'))
                                    k += 1;
                                if (e > j + 2 && k < s.length && s[k] == ':')
                                    addName(set, s[j + 1 .. e - 1]);
                            }
                            j = e;
                            continue;
                        }
                        if (d == '`')
                        {
                            j = skipString(s, j);
                            continue;
                        }
                        if (d == '/' && j + 1 < s.length && s[j + 1] == '/')
                        {
                            j += 2;
                            while (j < s.length && s[j] != '\n')
                                j += 1;
                            continue;
                        }
                        if (d == '{' || d == '(' || d == '[')
                        {
                            depth += 1;
                            j += 1;
                            continue;
                        }
                        if (d == '}' || d == ')' || d == ']')
                        {
                            depth -= 1;
                            j += 1;
                            continue;
                        }
                        if (depth == 1 && (isStart(d) || d == '"' || d == '\''))
                        {
                            size_t start;
                            size_t n;
                            if (d == '"' || d == '\'')
                            {
                                start = j + 1;
                                size_t e = skipString(s, j);
                                n = e > start ? e - start - 1 : 0;
                                j = e;
                            }
                            else
                            {
                                start = j;
                                while (j < s.length && isPart(s[j]))
                                    j += 1;
                                n = j - start;
                            }
                            size_t k = j;
                            while (k < s.length && (s[k] == ' ' || s[k] == '\t' || s[k] == '\n'))
                                k += 1;
                            if (k < s.length && (s[k] == ':' || s[k] == ',' || s[k] == '}'))
                                addName(set, s[start .. start + n]);
                            continue;
                        }
                        j += 1;
                    }
                    i = j;
                    prev = Tok.value;
                    continue;
                }
            }
            i = j;
            continue;
        }
        if (startsWith(s, i, "Object.defineProperty"))
        {
            // Take the first quoted name inside the call, then skip to the
            // matching close paren. Jumping a fixed window past the call used
            // to swallow the `exports.x = ...` assignments that follow it.
            size_t j = i + 20;
            while (j < s.length && s[j] != '(')
                j += 1;
            if (j < s.length)
            {
                size_t p = j;
                int depth = 0;
                size_t nameStart = 0;
                size_t nameLen = 0;
                while (p < s.length)
                {
                    char d = s[p];
                    if (d == '\'' || d == '"' || d == '`')
                    {
                        size_t e = skipString(s, p);
                        if (nameLen == 0 && depth == 1 && e > p + 1)
                        {
                            nameStart = p + 1;
                            nameLen = e - p - 2;
                        }
                        p = e;
                        continue;
                    }
                    if (d == '(')
                    {
                        depth += 1;
                        p += 1;
                        continue;
                    }
                    if (d == ')')
                    {
                        depth -= 1;
                        p += 1;
                        if (depth == 0)
                            break;
                        continue;
                    }
                    p += 1;
                }
                if (nameLen > 0)
                    addName(set, s[nameStart .. nameStart + nameLen]);
                i = p;
                prev = Tok.value;
                continue;
            }
            i = j;
            continue;
        }
        if (isStart(c))
        {
            size_t j = i;
            while (j < s.length && isPart(s[j]))
                j += 1;
            lastIdent = i;
            lastIdentLen = j - i;
            prev = Tok.ident;
            i = j;
            continue;
        }
        if (isDigit(c))
        {
            size_t j = i;
            while (j < s.length && (isPart(s[j]) || s[j] == '.'))
                j += 1;
            prev = Tok.number;
            i = j;
            continue;
        }
        prev = Tok.punct;
        // `=>` opens an expression even though `>` alone ends one; without
        // this an arrow function returning a regex (`str => /.../.test(str)`)
        // is read as division and its body is scanned as code.
        prevPunct = (c == '>' && i > 0 && s[i - 1] == '=') ? '=' : c;
        i += 1;
    }
}

// Public boundary: the caller owns `src` for `len` bytes.
void collectCjsExportNames(const(char)* src, size_t len, NameSet* set) @trusted @nogc nothrow
{
    if (src is null || set is null)
        return;
    scanNames(src[0 .. len], *set);
}

// ---------------------------------------------------------------------------
// Tests: the scanner is pure slice code, so these are @safe and need no
// runtime, no files and no QuickJS.
// ---------------------------------------------------------------------------

private bool hasName(ref NameSet set, const(char)[] name) @safe @nogc nothrow
{
    foreach (i; 0 .. set.count)
        if (storedName(set.names[i]) == name)
            return true;
    return false;
}

@safe unittest
{
    NameSet set;
    addName(set, "alpha");
    addName(set, "beta");
    addName(set, "alpha");
    addName(set, "class");        // reserved
    addName(set, "gamma");
    assert(set.count == 3);
    assert(storedName(set.names[0]) == "alpha");
    assert(storedName(set.names[1]) == "beta");
    assert(storedName(set.names[2]) == "gamma");

    // Linear, not quadratic: 20k names is a few milliseconds.
    char[16] name;
    foreach (i; 0 .. 20_000)
    {
        size_t n = 0;
        int v = cast(int) i;
        name[n++] = 'k';
        char[8] digits;
        int d = 0;
        do { digits[d++] = cast(char) ('0' + v % 10); v /= 10; } while (v != 0);
        while (d > 0) name[n++] = digits[--d];
        addName(set, name[0 .. n]);
    }
    assert(set.count == 20_003);
    nameSetFree(set);
    assert(set.names is null && set.count == 0 && set.slots is null);
}

@safe unittest
{
    // The patterns the ESM facade depends on.
    static immutable string src = `
        exports.a = 1;
        exports.b = 2;
        module.exports.c = 3;
        module.exports = { d, "e": 4, f: 5 };
        Object.defineProperty(exports, "g", { enumerable: true });
        // exports.commented = 1;
        const re = /"[^"]*exports.inRegex = 1"/;
        const div = 4 / 2;
        exports.class = 1;          // reserved word: not a legal export
    `;
    NameSet set;
    scanNames(src, set);
    assert(hasName(set, "a"));
    assert(hasName(set, "b"));
    assert(hasName(set, "c"));
    assert(hasName(set, "d"));
    assert(hasName(set, "e"));
    assert(hasName(set, "f"));
    assert(hasName(set, "g"));
    assert(!hasName(set, "commented"));
    assert(!hasName(set, "inRegex"));
    assert(!hasName(set, "class"));
    assert(set.count == 7, "unexpected names collected");
    nameSetFree(set);
}

@safe unittest
{
    // A regex body must not be scanned as code even when it contains an
    // assignment-looking string; this is the globby@16 regression.
    static immutable string src = `
        const ignored = /["']/g;
        module.exports.isPathValid = function () {};
        exports.after = 1;
    `;
    NameSet set;
    scanNames(src, set);
    assert(hasName(set, "isPathValid"));
    assert(hasName(set, "after"));
    assert(set.count == 2);
    nameSetFree(set);
}
