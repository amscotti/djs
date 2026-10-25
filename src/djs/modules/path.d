module djs.modules.path;

import core.stdc.errno : EINTR, ENOENT, ENOMEM, errno;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcmp, memcpy, strlen;
import core.sys.posix.fcntl : O_RDONLY, open;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : S_ISDIR, S_ISREG, fstat, stat, stat_t;
import core.sys.posix.unistd : close, read;

import djs.modules.json : jsonDecodeString;

enum size_t maxSourceFileSize = 64 * 1024 * 1024;

char* xstrdup(const(char)* s) @nogc nothrow
{
    if (s is null)
        return null;
    size_t n = strlen(s);
    char* p = cast(char*) malloc(n + 1);
    if (p is null)
        return null;
    memcpy(p, s, n + 1);
    return p;
}

// The public surface takes C strings because callers are C-shaped. The logic
// below is slice-based: `asSlice` is the only function that trusts a NUL
// terminator, and everything it feeds is `pure @safe` and directly testable.
private @trusted const(char)[] asSlice(const(char)* s) @nogc nothrow
{
    // Invariant: `s` is either null or NUL-terminated. strlen is the only read
    // past the pointer, and the resulting slice is bounded by it.
    return s is null ? null : s[0 .. strlen(s)];
}

pure @safe @nogc nothrow bool isAbsoluteSlice(const(char)[] p)
{
    return p.length > 0 && p[0] == '/';
}

// True when the specifier is a path rather than a bare module name: absolute
// ("/x") or explicitly relative ("./x", "../x"). A lone "." is not a path.
pure @safe @nogc nothrow bool isPathLikeSlice(const(char)[] s)
{
    if (s.length > 0 && s[0] == '/')
        return true;
    if (s.length >= 2 && s[0] == '.' && s[1] == '/')
        return true;
    return s.length >= 3 && s[0] == '.' && s[1] == '.' && s[2] == '/';
}

// Adapters: @trusted because the only unchecked act is reading the C string
// once in asSlice, under the documented contract that callers pass either null
// or a NUL-terminated buffer. Everything else is @safe slice code.
@trusted bool isAbsolutePath(const(char)* p) @nogc nothrow
{
    return isAbsoluteSlice(asSlice(p));
}

@trusted bool isPathLike(const(char)* s) @nogc nothrow
{
    return isPathLikeSlice(asSlice(s));
}

// Join with exactly one separator. Caller frees.
char* pathJoin(const(char)* a, const(char)* b) @nogc nothrow
{
    if (a is null || a[0] == 0)
        return xstrdup(b);
    if (b is null || b[0] == 0)
        return xstrdup(a);
    size_t la = strlen(a);
    size_t lb = strlen(b);
    bool needSlash = a[la - 1] != '/';
    char* p = cast(char*) malloc(la + (needSlash ? 1 : 0) + lb + 1);
    if (p is null)
        return null;
    memcpy(p, a, la);
    size_t off = la;
    if (needSlash)
        p[off++] = '/';
    memcpy(p + off, b, lb);
    p[off + lb] = 0;
    return p;
}

// Directory part, without the trailing separator ("/" for a root child).
char* dirNameAlloc(const(char)* p) @nogc nothrow
{
    if (p is null)
        return null;
    size_t n = strlen(p);
    while (n > 1 && p[n - 1] == '/')
        n -= 1;
    size_t cut = n;
    while (cut > 0 && p[cut - 1] != '/')
        cut -= 1;
    if (cut == 0)
        return xstrdup(".");
    if (cut == 1)
        return xstrdup("/");
    char* d = cast(char*) malloc(cut);
    if (d is null)
        return null;
    memcpy(d, p, cut - 1);
    d[cut - 1] = 0;
    return d;
}

// realpath(3) with a malloc'd result; NULL on failure (ENOENT and friends).
char* realPathAlloc(const(char)* p) @nogc nothrow
{
    if (p is null)
        return null;
    return realpath(p, null);
}

int pathKind(const(char)* p) @nogc nothrow
{
    stat_t st = void;
    if (p is null || stat(p, &st) != 0)
        return 0;
    if (S_ISDIR(st.st_mode))
        return 2;
    return 1;
}

bool isDir(const(char)* p) @nogc nothrow
{
    return pathKind(p) == 2;
}

bool isFile(const(char)* p) @nogc nothrow
{
    return pathKind(p) == 1;
}

pure @safe @nogc nothrow bool endsWithSlice(const(char)[] p, const(char)[] suffix)
{
    return p.length >= suffix.length && p[$ - suffix.length .. $] == suffix;
}

@trusted bool hasSuffix(const(char)* p, const(char)* suffix) @nogc nothrow
{
    return endsWithSlice(asSlice(p), asSlice(suffix));
}

// True when `path` is `root` itself or lives below it. Both are canonical.
pure @safe @nogc nothrow bool withinSlice(const(char)[] root, const(char)[] path)
{
    if (root.length == 0 || path.length < root.length)
        return false;
    if (path[0 .. root.length] != root)
        return false;
    if (path.length == root.length)
        return true;
    if (root[$ - 1] == '/')
        return true;
    return path[root.length] == '/';
}

@trusted bool pathWithin(const(char)* root, const(char)* path) @nogc nothrow
{
    return withinSlice(asSlice(root), asSlice(path));
}

// A shebang line is a comment to the engine: replace "#!" with "//" so byte
// offsets (and therefore line/column numbers in stack traces) stay identical.
void neutraliseShebang(char* src, size_t len) @nogc nothrow
{
    if (src is null || len < 2 || src[0] != '#' || src[1] != '!')
        return;
    src[0] = '/';
    src[1] = '/';
}

bool readFileAlloc(const(char)* path, char** dest, size_t* outLen,
                   int* err) @nogc nothrow
{
    *dest = null;
    *outLen = 0;
    *err = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0)
    {
        *err = errno;
        return false;
    }
    // One close for every exit below: the error paths only have to free the
    // buffer they own.
    scope(exit) close(fd);
    stat_t st = void;
    size_t cap = 8192;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0)
    {
        if (st.st_size > maxSourceFileSize)
        {
            *err = 27; // EFBIG
            return false;
        }
        cap = cast(size_t) st.st_size + 1;
    }
    char* buf = cast(char*) malloc(cap);
    if (buf is null)
    {
        *err = ENOMEM;
        return false;
    }
    size_t len = 0;
    // `cap` counts the NUL terminator: reads use cap - len - 1, so the
    // buffer is "full" for content purposes at len + 1 >= cap — that is
    // the grow condition. (Comparing len == cap never fired, which silently
    // truncated any file whose size was not captured by the initial fstat —
    // procfs, FIFOs, files that grew.)
    for (;;)
    {
        if (len + 1 >= cap)
        {
            if (cap >= maxSourceFileSize)
            {
                free(buf);
                *err = 27;
                return false;
            }
            size_t next = cap * 2;
            if (next > maxSourceFileSize)
                next = maxSourceFileSize;
            if (next <= cap)
            {
                free(buf);
                *err = 27;
                return false;
            }
            char* grown = cast(char*) realloc(buf, next);
            if (grown is null)
            {
                free(buf);
                *err = ENOMEM;
                return false;
            }
            buf = grown;
            cap = next;
        }
        ptrdiff_t n = read(fd, buf + len, cap - len - 1);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            *err = errno;
            free(buf);
            return false;
        }
        if (n == 0)
            break;
        len += cast(size_t) n;
    }
    buf[len] = 0;
    *dest = buf;
    *outLen = len;
    return true;
}

// Read the value of a top-level-ish `"key": "value"` pair without a JSON
// parser. Only used for package.json's `type` and `main` in v0.1; a malformed
// file yields no value rather than a crash.
char* packageJsonValue(const(char)* path, const(char)* key) @nogc nothrow
{
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(path, &src, &len, &err))
        return null;
    char* result = null;
    size_t kl = strlen(key);
    int depth = 0;
    size_t i = 0;
    while (i < len)
    {
        char c = src[i];
        if (c == '"')
        {
            // A string literal: find its end, honouring backslash escapes.
            size_t start = i + 1;
            size_t j = start;
            while (j < len)
            {
                if (src[j] == '\\')
                {
                    j += 2;
                    continue;
                }
                if (src[j] == '"')
                    break;
                j += 1;
            }
            if (j >= len)
                break;
            // Only a key at the top level of the object counts: nested objects
            // such as "repository": { "type": "git" } must not shadow it.
            if (depth == 1 && j - start == kl && memcmp(src + start, key, kl) == 0)
            {
                size_t k = j + 1;
                while (k < len && (src[k] == ' ' || src[k] == '\t' || src[k] == '\n' || src[k] == '\r'))
                    k += 1;
                if (k < len && src[k] == ':')
                {
                    k += 1;
                    while (k < len && (src[k] == ' ' || src[k] == '\t' || src[k] == '\n' || src[k] == '\r'))
                        k += 1;
                    if (k < len && src[k] == '"')
                    {
                        size_t vstart = k + 1;
                        size_t v = vstart;
                        while (v < len)
                        {
                            if (src[v] == '\\')
                            {
                                v += 2;
                                continue;
                            }
                            if (src[v] == '"')
                                break;
                            v += 1;
                        }
                        if (v < len)
                        {
                            size_t n = v - vstart;
                            // Decode escapes: a value written as
                            // ".\/lib\/x.js" or "mod\u0075le" must resolve
                            // the same as its plain form. A malformed escape
                            // means the file is not valid JSON; treat the
                            // key as absent.
                            result = jsonDecodeString(src, vstart, v);
                            break;
                        }
                    }
                }
            }
            i = j + 1;
            continue;
        }
        if (c == '{' || c == '[')
            depth += 1;
        else if (c == '}' || c == ']')
            depth -= 1;
        i += 1;
    }
    free(src);
    return result;
}

// Root used for module containment: the directory of the nearest package.json
// at or above the entry (so a package's whole tree is importable and its
// "type" applies to subdirectories), else the entry's own directory. Canonical.
char* projectRootFor(const(char)* entryPath) @nogc nothrow
{
    char* canonical = realPathAlloc(entryPath);
    if (canonical is null)
        return null;
    char* dir = dirNameAlloc(canonical);
    free(canonical);
    if (dir is null)
        return null;
    char* found = nearestPackageDir(dir, null);
    if (found !is null)
    {
        free(dir);
        return found;
    }
    return dir;
}

// Directory of the nearest package.json walking up from `startDir`, stopping
// at `root` (inclusive). Returns a malloc'd directory path, or null.
char* nearestPackageDir(const(char)* startDir, const(char)* root) @nogc nothrow
{
    char* dir = xstrdup(startDir);
    if (dir is null)
        return null;
    for (;;)
    {
        char* pkg = pathJoin(dir, "package.json");
        if (pkg is null)
            break;
        if (isFile(pkg))
        {
            free(pkg);
            return dir;
        }
        free(pkg);
        if (root !is null && strcmp(dir, root) == 0)
            break;
        char* parent = dirNameAlloc(dir);
        if (parent is null)
            break;
        bool same = strcmp(parent, dir) == 0;
        free(dir);
        dir = parent;
        if (same)
            break;
        if (root !is null && !pathWithin(root, dir))
            break;
    }
    free(dir);
    return null;
}

private int strcmp(const(char)* a, const(char)* b) pure @trusted @nogc nothrow
{
    size_t i = 0;
    while (a[i] != 0 && a[i] == b[i])
        i += 1;
    return cast(int) (cast(ubyte) a[i]) - cast(int) (cast(ubyte) b[i]);
}

@safe unittest
{
    // Predicates: the C-string adapters go through asSlice, so these cover the
    // same code the loader runs.
    assert(isAbsoluteSlice("/a/b"));
    assert(!isAbsoluteSlice("a/b"));
    assert(!isAbsoluteSlice(""));

    assert(isPathLikeSlice("/a"));
    assert(isPathLikeSlice("./a"));
    assert(isPathLikeSlice("../a"));
    assert(!isPathLikeSlice("."));
    assert(!isPathLikeSlice(".hidden"));
    assert(!isPathLikeSlice("..hidden"));

    assert(endsWithSlice("a/b.js", ".js"));
    assert(endsWithSlice("a/b.js", ""));
    assert(!endsWithSlice("a/b.js", ".mjs"));
    assert(!endsWithSlice(".js", "a.js"));

    assert(withinSlice("/root", "/root"));
    assert(withinSlice("/root", "/root/x"));
    assert(withinSlice("/root/", "/root/x"));
    assert(!withinSlice("/root/", "/rootx"));
    assert(!withinSlice("/root", "/rooted"));
    assert(!withinSlice("/root", "/"));
    assert(!withinSlice("", "/x"));
}

@safe unittest
{
    // Adapters must agree with the slice cores, including null.
    assert(isAbsolutePath("/tmp"));
    assert(!isAbsolutePath(null));
    assert(isPathLike("./x"));
    assert(!isPathLike(null));
    assert(hasSuffix("mod.js", ".js"));
    assert(!hasSuffix(null, ".js"));
    assert(hasSuffix("x", null));
    assert(pathWithin("/a", "/a/b"));
    assert(!pathWithin(null, "/a"));
}
