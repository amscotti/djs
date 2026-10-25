module djs.apis.crypto;

// Hash, HMAC and CSPRNG primitives backed by libcrypto. Only the mechanisms
// needed by the Node-shaped surface are exposed; algorithms are fixed by name
// (no engine loading, no provider configuration) so the binary's behaviour
// does not depend on an OpenSSL config file.

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strcmp;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.permissions : Perm, permissionCheck, permissionThrow;
import djs.runtime : Runtime, guarded, runtimeOf;

// OpenSSL 3 opaque types and the stable EVP entry points. HMAC_* are
// deprecated in 3.0 but remain exported; they are used instead of EVP_MAC to
// keep the binding small and ABI-stable.
private struct evp_pkey_st;
private struct bio_st;
private alias EVP_PKEY = evp_pkey_st;
private alias BIO = bio_st;

private struct evp_cipher_st;
private struct evp_cipher_ctx_st;
private struct evp_pkey_ctx_st;
private alias EVP_CIPHER = evp_cipher_st;
private alias EVP_CIPHER_CTX = evp_cipher_ctx_st;
private alias EVP_PKEY_CTX = evp_pkey_ctx_st;

private struct evp_md_st;
private struct evp_md_ctx_st;
private struct hmac_ctx_st;
private struct engine_st;
private alias EVP_MD = evp_md_st;
private alias EVP_MD_CTX = evp_md_ctx_st;
private alias HMAC_CTX = hmac_ctx_st;

extern(C) {
    EVP_MD* EVP_sha1() nothrow @nogc;
    EVP_MD* EVP_sha256() nothrow @nogc;
    EVP_MD* EVP_sha384() nothrow @nogc;
    EVP_MD* EVP_sha512() nothrow @nogc;
    EVP_MD* EVP_md5() nothrow @nogc;
    EVP_MD_CTX* EVP_MD_CTX_new() nothrow @nogc;
    void EVP_MD_CTX_free(EVP_MD_CTX*) nothrow @nogc;
    int EVP_DigestInit_ex(EVP_MD_CTX*, const(EVP_MD)*, engine_st*) nothrow @nogc;
    int EVP_DigestUpdate(EVP_MD_CTX*, const(void)*, size_t) nothrow @nogc;
    int EVP_DigestFinal_ex(EVP_MD_CTX*, ubyte*, uint*) nothrow @nogc;

    HMAC_CTX* HMAC_CTX_new() nothrow @nogc;
    void HMAC_CTX_free(HMAC_CTX*) nothrow @nogc;
    int HMAC_Init_ex(HMAC_CTX*, const(void)*, int, const(EVP_MD)*, engine_st*) nothrow @nogc;
    int HMAC_Update(HMAC_CTX*, const(ubyte)*, size_t) nothrow @nogc;
    int HMAC_Final(HMAC_CTX*, ubyte*, uint*) nothrow @nogc;

    int RAND_bytes(ubyte*, int) nothrow @nogc;

    const(EVP_CIPHER)* EVP_aes_128_gcm() nothrow @nogc;
    const(EVP_CIPHER)* EVP_aes_256_gcm() nothrow @nogc;
    const(EVP_CIPHER)* EVP_aes_128_cbc() nothrow @nogc;
    const(EVP_CIPHER)* EVP_aes_256_cbc() nothrow @nogc;
    EVP_CIPHER_CTX* EVP_CIPHER_CTX_new() nothrow @nogc;
    void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX*) nothrow @nogc;
    int EVP_EncryptInit_ex(EVP_CIPHER_CTX*, const(EVP_CIPHER)*, engine_st*, const(ubyte)*, const(ubyte)*) nothrow @nogc;
    int EVP_EncryptUpdate(EVP_CIPHER_CTX*, ubyte*, int*, const(ubyte)*, int) nothrow @nogc;
    int EVP_EncryptFinal_ex(EVP_CIPHER_CTX*, ubyte*, int*) nothrow @nogc;
    int EVP_DecryptInit_ex(EVP_CIPHER_CTX*, const(EVP_CIPHER)*, engine_st*, const(ubyte)*, const(ubyte)*) nothrow @nogc;
    int EVP_DecryptUpdate(EVP_CIPHER_CTX*, ubyte*, int*, const(ubyte)*, int) nothrow @nogc;
    int EVP_DecryptFinal_ex(EVP_CIPHER_CTX*, ubyte*, int*) nothrow @nogc;
    int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX*, int, int, void*) nothrow @nogc;
    // OpenSSL 3 exported accessors (the historical names are header macros).
    int EVP_CIPHER_get_key_length(const(EVP_CIPHER)*) nothrow @nogc;
    int EVP_CIPHER_get_iv_length(const(EVP_CIPHER)*) nothrow @nogc;

    int PKCS5_PBKDF2_HMAC(const(char)*, int, const(ubyte)*, int, int, const(EVP_MD)*, int, ubyte*) nothrow @nogc;
    EVP_PKEY_CTX* EVP_PKEY_CTX_new_from_name(void*, const(char)*, const(char)*) nothrow @nogc;
    void EVP_PKEY_CTX_free(EVP_PKEY_CTX*) nothrow @nogc;
    int EVP_PKEY_derive_init(EVP_PKEY_CTX*) nothrow @nogc;
    int EVP_PKEY_derive(EVP_PKEY_CTX*, ubyte*, size_t*) nothrow @nogc;
    int EVP_PKEY_CTX_ctrl(EVP_PKEY_CTX*, int, int, int, void*) nothrow @nogc;
    int EVP_MD_get_size(const(EVP_MD)*) nothrow @nogc;
    EVP_PKEY* PEM_read_bio_PrivateKey(BIO*, EVP_PKEY**, void*, void*) nothrow @nogc;
    EVP_PKEY* PEM_read_bio_PUBKEY(BIO*, EVP_PKEY**, void*, void*) nothrow @nogc;
    void EVP_PKEY_free(EVP_PKEY*) nothrow @nogc;
    BIO* BIO_new_mem_buf(const(void)*, int) nothrow @nogc;
    BIO* BIO_new_file(const(char)*, const(char)*) nothrow @nogc;
    void BIO_free(BIO*) nothrow @nogc;
    int EVP_DigestSignInit(EVP_MD_CTX*, void**, const(EVP_MD)*, engine_st*, EVP_PKEY*) nothrow @nogc;
    int EVP_DigestSign(EVP_MD_CTX*, ubyte*, size_t*, const(ubyte)*, size_t) nothrow @nogc;
    int EVP_DigestVerifyInit(EVP_MD_CTX*, void**, const(EVP_MD)*, engine_st*, EVP_PKEY*) nothrow @nogc;
    int EVP_DigestVerify(EVP_MD_CTX*, const(ubyte)*, size_t, const(ubyte)*, size_t) nothrow @nogc;
    int EVP_PBE_scrypt(const(char)*, size_t, const(ubyte)*, size_t, ulong, ulong, ulong, ulong, ubyte*, size_t) nothrow @nogc;
    int EVP_PKEY_keygen_init(EVP_PKEY_CTX*) nothrow @nogc;
    struct rsa_st; alias RSA = rsa_st;
    struct bignum_st; alias BIGNUM = bignum_st;
    struct ec_key_st; alias EC_KEY = ec_key_st;
    RSA* RSA_new() nothrow @nogc;
    void RSA_free(RSA*) nothrow @nogc;
    int RSA_generate_key_ex(RSA*, int, BIGNUM*, void*) nothrow @nogc;
    BIGNUM* BN_new() nothrow @nogc;
    void BN_free(BIGNUM*) nothrow @nogc;
    int BN_set_word(BIGNUM*, ulong) nothrow @nogc;
    EVP_PKEY* EVP_PKEY_new() nothrow @nogc;
    int EVP_PKEY_assign(EVP_PKEY*, int, void*) nothrow @nogc;
    EC_KEY* EC_KEY_new_by_curve_name(int) nothrow @nogc;
    struct x509_st; alias X509 = x509_st;
    struct x509_name_st; alias X509_NAME = x509_name_st;
    struct asn1_string_st; alias ASN1_TIME = asn1_string_st; alias ASN1_INTEGER = asn1_string_st;
    X509* PEM_read_bio_X509(BIO*, X509**, void*, void*) nothrow @nogc;
    void X509_free(X509*) nothrow @nogc;
    X509_NAME* X509_get_subject_name(const(X509)*) nothrow @nogc;
    X509_NAME* X509_get_issuer_name(const(X509)*) nothrow @nogc;
    char* X509_NAME_oneline(const(X509_NAME)*, char*, int) nothrow @nogc;
    const(ASN1_TIME)* X509_get0_notBefore(const(X509)*) nothrow @nogc;
    const(ASN1_TIME)* X509_get0_notAfter(const(X509)*) nothrow @nogc;
    int ASN1_TIME_print(BIO*, const(ASN1_TIME)*) nothrow @nogc;
    int X509_digest(const(X509)*, const(EVP_MD)*, ubyte*, uint*) nothrow @nogc;
    ASN1_INTEGER* X509_get_serialNumber(X509*) nothrow @nogc;
    int i2a_ASN1_INTEGER(BIO*, const(ASN1_INTEGER)*) nothrow @nogc;
    int X509_check_host(X509*, const(char)*, size_t, uint, char**) nothrow @nogc;
    int EC_KEY_generate_key(EC_KEY*) nothrow @nogc;
    void EC_KEY_free(EC_KEY*) nothrow @nogc;
    int EVP_PKEY_keygen(EVP_PKEY_CTX*, EVP_PKEY**) nothrow @nogc;
    pragma(mangle, "EVP_PKEY_CTX_ctrl") int EVP_PKEY_CTX_ctrl6(EVP_PKEY_CTX*, int, int, int, int, void*) nothrow @nogc;
    struct bio_method_st;
    alias BIO_METHOD = bio_method_st;
    BIO* BIO_new(const(BIO_METHOD)*) nothrow @nogc;
    const(BIO_METHOD)* BIO_s_mem() nothrow @nogc;
    long BIO_ctrl(BIO*, int, long, void*) nothrow @nogc;
    int PEM_write_bio_PrivateKey(BIO*, EVP_PKEY*, const(EVP_CIPHER)*, const(ubyte)*, int, void*, void*) nothrow @nogc;
    int PEM_write_bio_PUBKEY(BIO*, EVP_PKEY*) nothrow @nogc;
    void CRYPTO_free(void*, const(char)*, int) nothrow @nogc;
}

private enum int EVP_CTRL_AEAD_SET_IVLEN = 0x9;
private enum int EVP_CTRL_AEAD_GET_TAG = 0x10;
private enum int EVP_CTRL_AEAD_SET_TAG = 0x11;
private enum int EVP_PKEY_ALG_CTRL = 0x1000;
private enum int EVP_PKEY_CTRL_HKDF_MD = EVP_PKEY_ALG_CTRL + 3;
private enum int EVP_PKEY_CTRL_HKDF_SALT = EVP_PKEY_ALG_CTRL + 1;
private enum int EVP_PKEY_CTRL_HKDF_KEY = EVP_PKEY_ALG_CTRL + 0;
private enum int EVP_PKEY_CTRL_HKDF_INFO = EVP_PKEY_ALG_CTRL + 2;

private enum int maxSlots = 64;
private enum int maxDigest = 64;

private struct Slot
{
    bool used;
    bool hmac;
    uint id;
    EVP_MD_CTX* md;
    HMAC_CTX* mac;
    Runtime* rt;
}

private Slot[maxSlots] slots;
private uint nextId = 1;

private const(EVP_MD)* mdFor(const(char)* name) @nogc nothrow
{
    import core.stdc.string : strcmp;
    if (strcmp(name, "sha256") == 0) return EVP_sha256();
    if (strcmp(name, "sha1") == 0) return EVP_sha1();
    if (strcmp(name, "sha384") == 0) return EVP_sha384();
    if (strcmp(name, "sha512") == 0) return EVP_sha512();
    if (strcmp(name, "md5") == 0) return EVP_md5();
    return null;
}

// Accepts a string, an ArrayBuffer or any ArrayBuffer view and yields a byte
// span valid until bytesRelease(). The ArrayBuffer that owns the span is kept
// alive in `holder` because QuickJS only guarantees the pointer while it lives.
private struct Bytes
{
    const(ubyte)* ptr;
    size_t len;
    const(char)* cstr;
    JSValue holder;
}

private bool bytesAcquire(JSContext* ctx, JSValueConst val, ref Bytes b) @nogc nothrow
{
    b = Bytes.init;
    b.holder = jsUndefined();
    const(char)* s = null;
    size_t slen = 0;
    if (jsIsString(val) && toStringView(ctx, val, &s, &slen))
    {
        b.cstr = s;
        b.ptr = cast(const(ubyte)*) s;
        b.len = slen;
        return true;
    }
    if (JS_IsArrayBuffer(val))
    {
        size_t size = 0;
        ubyte* p = JS_GetArrayBuffer(ctx, &size, val);
        if (p is null) return false;
        b.ptr = p;
        b.len = size;
        b.holder = JS_DupValue(ctx, val);
        return true;
    }
    size_t off = 0, len = 0, bpe = 0;
    JSValue ab = JS_GetTypedArrayBuffer(ctx, val, &off, &len, &bpe);
    if (jsIsException(ab))
    {
        JS_FreeValue(ctx, ab);
        return false;
    }
    size_t size = 0;
    ubyte* p = JS_GetArrayBuffer(ctx, &size, ab);
    if (p is null || off > size || len > size - off)
    {
        JS_FreeValue(ctx, ab);
        return false;
    }
    b.ptr = p + off;
    b.len = len;
    b.holder = ab;   // transfers ownership; released in bytesRelease
    return true;
}

private void bytesRelease(JSContext* ctx, ref Bytes b) @nogc nothrow
{
    if (b.cstr !is null) JS_FreeCString(ctx, b.cstr);
    if (!jsIsUndefined(b.holder)) JS_FreeValue(ctx, b.holder);
    b = Bytes.init;
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
    if (s.md !is null) EVP_MD_CTX_free(s.md);
    if (s.mac !is null) HMAC_CTX_free(s.mac);
    s.md = null;
    s.mac = null;
    s.used = false;
    s.id = 0;
    s.rt = null;
}

private void closeAll(Runtime* self) @nogc nothrow
{
    foreach (ref s; slots)
        if (s.used && s.rt is self)
            freeSlot(&s);
}

private extern(C) JSValue jsCryptoStartImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    import core.stdc.string : strlen;
    if (argc < 1)
        return throwTypeError(ctx, "createHash requires an algorithm");
    const(char)* name = null;
    size_t nlen = 0;
    if (!toStringView(ctx, argv[0], &name, &nlen))
        return jsException();
    scope(exit) JS_FreeCString(ctx, name);
    const(EVP_MD)* md = mdFor(name);
    if (md is null)
        return throwTypeError(ctx, "Digest method not supported");
    uint id = 0;
    Slot* s = allocSlot(runtimeOf(ctx), &id);
    if (s is null) return throwInternalError(ctx, "crypto table exhausted");
    s.hmac = false;
    s.md = EVP_MD_CTX_new();
    if (s.md is null || EVP_DigestInit_ex(s.md, md, null) != 1)
    {
        freeSlot(s);
        return throwInternalError(ctx, "digest init failed");
    }
    return jsInt(cast(int) id);
}
extern(C) JSValue jsCryptoStart(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCryptoStartImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCryptoStartHmacImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "createHmac requires (algorithm, key)");
    const(char)* name = null;
    size_t nlen = 0;
    if (!toStringView(ctx, argv[0], &name, &nlen))
        return jsException();
    scope(exit) JS_FreeCString(ctx, name);
    const(EVP_MD)* md = mdFor(name);
    if (md is null)
        return throwTypeError(ctx, "Digest method not supported");
    Bytes key;
    if (!bytesAcquire(ctx, argv[1], key))
        return throwTypeError(ctx, "key must be a string or Buffer");
    scope(exit) bytesRelease(ctx, key);
    if (key.len > int.max)
        return throwRangeError(ctx, "key too large");
    uint id = 0;
    Slot* s = allocSlot(runtimeOf(ctx), &id);
    if (s is null) return throwInternalError(ctx, "crypto table exhausted");
    s.hmac = true;
    s.mac = HMAC_CTX_new();
    if (s.mac is null || HMAC_Init_ex(s.mac, key.ptr, cast(int) key.len, md, null) != 1)
    {
        freeSlot(s);
        return throwInternalError(ctx, "hmac init failed");
    }
    return jsInt(cast(int) id);
}
extern(C) JSValue jsCryptoStartHmac(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCryptoStartHmacImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCryptoUpdateImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "hashUpdate requires (id, data)");
    Slot* s = findSlot(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid hash handle");
    Bytes data;
    if (!bytesAcquire(ctx, argv[1], data))
        return throwTypeError(ctx, "data must be a string, Buffer or ArrayBuffer");
    scope(exit) bytesRelease(ctx, data);
    int rc = s.hmac ? HMAC_Update(s.mac, data.ptr, data.len)
                    : EVP_DigestUpdate(s.md, data.ptr, data.len);
    if (rc != 1)
    {
        freeSlot(s);
        return throwInternalError(ctx, "digest update failed");
    }
    return jsUndefined();
}
extern(C) JSValue jsCryptoUpdate(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCryptoUpdateImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCryptoDigestImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "hashDigest requires an id");
    Slot* s = findSlot(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid hash handle");
    ubyte[maxDigest] digestBuf = void;
    uint n = 0;
    int rc = s.hmac ? HMAC_Final(s.mac, digestBuf.ptr, &n) : EVP_DigestFinal_ex(s.md, digestBuf.ptr, &n);
    freeSlot(s);
    if (rc != 1)
        return throwInternalError(ctx, "digest final failed");
    JSValue buf = JS_NewArrayBufferCopy(ctx, digestBuf.ptr, n);
    return buf;
}
extern(C) JSValue jsCryptoDigest(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCryptoDigestImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTimingSafeEqualImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    if (argc < 2) return throwTypeError(ctx, "timingSafeEqual requires two inputs");
    Bytes a, b;
    if (!bytesAcquire(ctx, argv[0], a))
        return throwTypeError(ctx, "input must be a string or Buffer");
    scope(exit) bytesRelease(ctx, a);
    if (!bytesAcquire(ctx, argv[1], b))
        return throwTypeError(ctx, "input must be a string or Buffer");
    scope(exit) bytesRelease(ctx, b);
    if (a.len != b.len)
        return throwRangeError(ctx, "input buffers must have the same byte length");
    ubyte diff = 0;
    for (size_t i = 0; i < a.len; ++i)
        diff |= a.ptr[i] ^ b.ptr[i];
    return jsBool(diff == 0);
}
extern(C) JSValue jsTimingSafeEqual(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTimingSafeEqualImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsCryptoRandomImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int n = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &n))
        return throwTypeError(ctx, "randomBytes requires a size");
    if (n < 0 || n > 65536)
        return throwRangeError(ctx, "randomBytes size out of range");
    if (n == 0) return JS_NewArrayBufferCopy(ctx, null, 0);
    ubyte* p = cast(ubyte*) malloc(cast(size_t) n);
    if (p is null) return throwInternalError(ctx, "out of memory");
    scope(exit) free(p);
    if (RAND_bytes(p, n) != 1)
        return throwInternalError(ctx, "random generation failed");
    return JS_NewArrayBufferCopy(ctx, p, cast(size_t) n);
}
extern(C) JSValue jsCryptoRandom(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCryptoRandomImpl(ctx, thisVal, argc, argv); }

void cryptoCloseAll(Runtime* self) @nogc nothrow
{
    closeAll(self);
}



private EVP_PKEY* loadPemKey(JSContext* ctx, JSValueConst val, bool wantPrivate) @nogc nothrow
{
    Bytes b = void;
    if (!bytesAcquire(ctx, val, b)) return null;
    scope(exit) bytesRelease(ctx, b);
    bool isPem = b.len > 10 && b.ptr[0] == '-' && b.ptr[1] == '-';
    BIO* bio = null;
    if (isPem)
        bio = BIO_new_mem_buf(b.ptr, cast(int) b.len);
    else
    {
        // Treat the value as a file path. The NUL-terminated view is what the
        // BIO API needs; bytesAcquire already allocated it for strings.
        if (b.cstr is null) { throwTypeError(ctx, "key must be a PEM string or path"); return null; }
        if (!permissionCheck(Perm.read, b.cstr)) { permissionThrow(ctx, Perm.read, b.cstr); return null; }
        bio = BIO_new_file(b.cstr, "r");
    }
    if (bio is null) { throwInternalError(ctx, "cannot open key"); return null; }
    scope(exit) BIO_free(bio);
    EVP_PKEY* pkey = wantPrivate ? PEM_read_bio_PrivateKey(bio, null, null, null)
                                 : PEM_read_bio_PUBKEY(bio, null, null, null);
    if (pkey is null) { throwInternalError(ctx, wantPrivate ? "invalid private key" : "invalid public key"); return null; }
    return pkey;
}

private extern(C) JSValue jsSignImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 3 || !jsIsString(argv[0])) return throwTypeError(ctx, "sign requires (algorithm, data, key)");
    const(char)* an = null; size_t alen = 0;
    if (!toStringView(ctx, argv[0], &an, &alen)) return jsException();
    const(EVP_MD)* md = digestByName(an, alen);
    JS_FreeCString(ctx, an);
    if (md is null) return throwTypeError(ctx, "unsupported digest");
    Bytes data = void;
    if (!bytesAcquire(ctx, argv[1], data)) return jsException();
    scope(exit) bytesRelease(ctx, data);
    EVP_PKEY* pkey = loadPemKey(ctx, argv[2], true);
    if (pkey is null) return jsException();
    scope(exit) EVP_PKEY_free(pkey);
    EVP_MD_CTX* mctx = EVP_MD_CTX_new();
    if (mctx is null) return throwInternalError(ctx, "digest context failed");
    scope(exit) EVP_MD_CTX_free(mctx);
    if (EVP_DigestSignInit(mctx, null, md, null, pkey) != 1)
        return throwInternalError(ctx, "sign init failed");
    size_t siglen = 0;
    if (EVP_DigestSign(mctx, null, &siglen, data.ptr, data.len) != 1)
        return throwInternalError(ctx, "sign size failed");
    ubyte* sig = cast(ubyte*) malloc(siglen);
    if (sig is null) return throwInternalError(ctx, "out of memory");
    scope(exit) free(sig);
    if (EVP_DigestSign(mctx, sig, &siglen, data.ptr, data.len) != 1)
        return throwInternalError(ctx, "sign failed");
    return JS_NewArrayBufferCopy(ctx, sig, siglen);
}
extern(C) JSValue jsSign(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSignImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsVerifyImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 4 || !jsIsString(argv[0])) return throwTypeError(ctx, "verify requires (algorithm, data, key, signature)");
    const(char)* an = null; size_t alen = 0;
    if (!toStringView(ctx, argv[0], &an, &alen)) return jsException();
    const(EVP_MD)* md = digestByName(an, alen);
    JS_FreeCString(ctx, an);
    if (md is null) return throwTypeError(ctx, "unsupported digest");
    Bytes data = void, sig = void;
    if (!bytesAcquire(ctx, argv[1], data)) return jsException();
    if (!bytesAcquire(ctx, argv[3], sig)) { bytesRelease(ctx, data); return jsException(); }
    scope(exit) { bytesRelease(ctx, data); bytesRelease(ctx, sig); }
    EVP_PKEY* pkey = loadPemKey(ctx, argv[2], false);
    if (pkey is null) return jsException();
    scope(exit) EVP_PKEY_free(pkey);
    EVP_MD_CTX* mctx = EVP_MD_CTX_new();
    if (mctx is null) return throwInternalError(ctx, "digest context failed");
    scope(exit) EVP_MD_CTX_free(mctx);
    if (EVP_DigestVerifyInit(mctx, null, md, null, pkey) != 1)
        return throwInternalError(ctx, "verify init failed");
    int rc = EVP_DigestVerify(mctx, sig.ptr, sig.len, data.ptr, data.len);
    return jsBool(rc == 1);
}
extern(C) JSValue jsVerify(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsVerifyImpl(ctx, thisVal, argc, argv); }

private const(EVP_CIPHER)* cipherByName(const(char)* name, size_t len, bool* gcm) nothrow @nogc
{
    import core.stdc.string : strcmp;
    *gcm = false;
    char[32] buf = void;
    if (len >= buf.length) return null;
    foreach (i; 0 .. len) buf[i] = name[i];
    buf[len] = 0;
    if (strcmp(buf.ptr, "aes-128-gcm") == 0) { *gcm = true; return EVP_aes_128_gcm(); }
    if (strcmp(buf.ptr, "aes-256-gcm") == 0) { *gcm = true; return EVP_aes_256_gcm(); }
    if (strcmp(buf.ptr, "aes-128-cbc") == 0) return EVP_aes_128_cbc();
    if (strcmp(buf.ptr, "aes-256-cbc") == 0) return EVP_aes_256_cbc();
    return null;
}

private extern(C) JSValue jsCipherImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 5 || !jsIsString(argv[1]))
        return throwTypeError(ctx, "cipher requires (decrypt, algorithm, key, iv, input, aad, tag)");
    int decrypt = JS_ToBool(ctx, argv[0]);
    const(char)* alg = null;
    size_t alen = 0;
    if (!toStringView(ctx, argv[1], &alg, &alen)) return jsException();
    scope(exit) JS_FreeCString(ctx, alg);
    bool gcm = false;
    const(EVP_CIPHER)* cipher = cipherByName(alg, alen, &gcm);
    if (cipher is null) return throwTypeError(ctx, "unsupported cipher");
    Bytes key = void, iv = void, input = void, aad = void, tag = void;
    bool haveAad = argc > 5 && !jsIsNull(argv[5]) && !jsIsUndefined(argv[5]);
    bool haveTag = argc > 6 && !jsIsNull(argv[6]) && !jsIsUndefined(argv[6]);
    if (!bytesAcquire(ctx, argv[2], key)) return jsException();
    if (!bytesAcquire(ctx, argv[3], iv)) { bytesRelease(ctx, key); return jsException(); }
    if (!bytesAcquire(ctx, argv[4], input)) { bytesRelease(ctx, key); bytesRelease(ctx, iv); return jsException(); }
    if (haveAad && !bytesAcquire(ctx, argv[5], aad)) { bytesRelease(ctx, key); bytesRelease(ctx, iv); bytesRelease(ctx, input); return jsException(); }
    if (haveTag && !bytesAcquire(ctx, argv[6], tag)) { bytesRelease(ctx, key); bytesRelease(ctx, iv); bytesRelease(ctx, input); if (haveAad) bytesRelease(ctx, aad); return jsException(); }
    scope(exit)
    {
        bytesRelease(ctx, key); bytesRelease(ctx, iv); bytesRelease(ctx, input);
        if (haveAad) bytesRelease(ctx, aad);
        if (haveTag) bytesRelease(ctx, tag);
    }
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    if (c is null) return throwInternalError(ctx, "EVP_CIPHER_CTX_new failed");
    scope(exit) EVP_CIPHER_CTX_free(c);
    // EVP_*Init_ex has no length arguments: it reads the cipher's fixed
    // key/IV length from the supplied pointers regardless of the actual
    // buffer size. Validate both, or a short key reads past the end of a
    // QuickJS heap allocation inside OpenSSL.
    {
        int wantKey = EVP_CIPHER_get_key_length(cipher);
        int wantIv = EVP_CIPHER_get_iv_length(cipher);
        if (wantKey > 0 && cast(int) key.len != wantKey)
            return throwRangeError(ctx, "invalid key length");
        // GCM takes a caller-chosen IV length through SET_IVLEN below;
        // everything else must match the cipher's fixed IV length exactly.
        if (!gcm && wantIv > 0 && cast(int) iv.len != wantIv)
            return throwRangeError(ctx, "invalid IV length");
        if (gcm && iv.len < 1)
            return throwRangeError(ctx, "invalid IV length");
    }
    size_t outCap = input.len + 64;
    ubyte* outp = cast(ubyte*) malloc(outCap);
    if (outp is null) return throwInternalError(ctx, "out of memory");
    scope(exit) free(outp);
    int outl = 0, total = 0;
    if (gcm)
    {
        int rc = decrypt ? EVP_DecryptInit_ex(c, cipher, null, null, null)
                         : EVP_EncryptInit_ex(c, cipher, null, null, null);
        if (rc != 1) return throwInternalError(ctx, "cipher init failed");
        if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_IVLEN, cast(int) iv.len, null) != 1)
            return throwInternalError(ctx, "invalid IV length");
        rc = decrypt ? EVP_DecryptInit_ex(c, null, null, key.ptr, iv.ptr)
                     : EVP_EncryptInit_ex(c, null, null, key.ptr, iv.ptr);
        if (rc != 1) return throwInternalError(ctx, "cipher key init failed");
        if (decrypt)
        {
            if (!haveTag || tag.len == 0) return throwTypeError(ctx, "auth tag required");
            if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_TAG, cast(int) tag.len, cast(void*) tag.ptr) != 1)
                return throwInternalError(ctx, "invalid auth tag");
        }
    }
    else
    {
        int rc = decrypt ? EVP_DecryptInit_ex(c, cipher, null, key.ptr, iv.ptr)
                         : EVP_EncryptInit_ex(c, cipher, null, key.ptr, iv.ptr);
        if (rc != 1) return throwInternalError(ctx, "cipher init failed");
    }
    if (haveAad && aad.len > 0)
    {
        int aadOut = 0;
        int rc = decrypt ? EVP_DecryptUpdate(c, null, &aadOut, aad.ptr, cast(int) aad.len)
                         : EVP_EncryptUpdate(c, null, &aadOut, aad.ptr, cast(int) aad.len);
        if (rc != 1) return throwInternalError(ctx, "AAD update failed");
    }
    if (input.len > 0)
    {
        int rc = decrypt ? EVP_DecryptUpdate(c, outp, &outl, input.ptr, cast(int) input.len)
                         : EVP_EncryptUpdate(c, outp, &outl, input.ptr, cast(int) input.len);
        if (rc != 1) return throwInternalError(ctx, "cipher update failed");
        total = outl;
    }
    int fin = 0;
    int frc = decrypt ? EVP_DecryptFinal_ex(c, outp + total, &fin)
                      : EVP_EncryptFinal_ex(c, outp + total, &fin);
    if (frc != 1) return throwError(ctx, makeError(ctx, "bad decrypt", "ERR_CRYPTO_BAD_DECRYPT", null, "cipher"));
    total += fin;
    JSValue result = JS_NewObject(ctx);
    if (jsIsException(result)) return result;
    JS_SetPropertyStr(ctx, result, "data", JS_NewArrayBufferCopy(ctx, outp, total));
    if (!decrypt && gcm)
    {
        ubyte[16] tagOut = void;
        if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_GET_TAG, 16, &tagOut) != 1)
            return throwInternalError(ctx, "get tag failed");
        JS_SetPropertyStr(ctx, result, "tag", JS_NewArrayBufferCopy(ctx, tagOut.ptr, 16));
    }
    return result;
}
extern(C) JSValue jsCipher(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsCipherImpl(ctx, thisVal, argc, argv); }

private const(EVP_MD)* digestByName(const(char)* name, size_t len) nothrow @nogc
{
    import core.stdc.string : strcmp;
    char[16] buf = void;
    if (len >= buf.length) return null;
    foreach (i; 0 .. len) buf[i] = name[i];
    buf[len] = 0;
    if (strcmp(buf.ptr, "sha256") == 0) return EVP_sha256();
    if (strcmp(buf.ptr, "sha1") == 0) return EVP_sha1();
    if (strcmp(buf.ptr, "sha512") == 0) return EVP_sha512();
    if (strcmp(buf.ptr, "md5") == 0) return EVP_md5();
    return null;
}

private extern(C) JSValue jsPbkdf2Impl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 5 || !jsIsString(argv[4])) return throwTypeError(ctx, "pbkdf2 requires (password, salt, iterations, keylen, digest)");
    int iterations = 0, keylen = 0;
    if (!toInt32(ctx, argv[2], &iterations) || iterations <= 0 || !toInt32(ctx, argv[3], &keylen) || keylen <= 0)
        return throwTypeError(ctx, "invalid pbkdf2 parameters");
    // pbkdf2 runs to completion on the loop thread and cannot be interrupted
    // by the interpreter's deadline handler; bound the parameters so a
    // hostile script cannot pin the event loop (or the native heap) forever.
    if (iterations > 10_000_000)
        return throwRangeError(ctx, "pbkdf2 iterations too large");
    if (keylen > 8 * 1024 * 1024)
        return throwRangeError(ctx, "pbkdf2 key length too large");
    const(EVP_MD)* md = digestByName(null, 0);
    const(char)* dn = null; size_t dlen = 0;
    if (!toStringView(ctx, argv[4], &dn, &dlen)) return jsException();
    md = digestByName(dn, dlen);
    JS_FreeCString(ctx, dn);
    if (md is null) return throwTypeError(ctx, "unsupported digest");
    Bytes pass = void, salt = void;
    if (!bytesAcquire(ctx, argv[0], pass)) return jsException();
    if (!bytesAcquire(ctx, argv[1], salt)) { bytesRelease(ctx, pass); return jsException(); }
    scope(exit) { bytesRelease(ctx, pass); bytesRelease(ctx, salt); }
    ubyte* outp = cast(ubyte*) malloc(cast(size_t) keylen);
    if (outp is null) return throwInternalError(ctx, "out of memory");
    scope(exit) free(outp);
    if (PKCS5_PBKDF2_HMAC(cast(const(char)*) pass.ptr, cast(int) pass.len, salt.ptr, cast(int) salt.len,
                          iterations, md, keylen, outp) != 1)
        return throwInternalError(ctx, "pbkdf2 failed");
    return JS_NewArrayBufferCopy(ctx, outp, cast(size_t) keylen);
}
extern(C) JSValue jsPbkdf2(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsPbkdf2Impl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsHkdfImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 5 || !jsIsString(argv[0])) return throwTypeError(ctx, "hkdf requires (digest, ikm, salt, info, keylen)");
    int keylen = 0;
    if (!toInt32(ctx, argv[4], &keylen) || keylen <= 0) return throwTypeError(ctx, "invalid key length");
    const(char)* dn = null; size_t dlen = 0;
    if (!toStringView(ctx, argv[0], &dn, &dlen)) return jsException();
    const(EVP_MD)* md = digestByName(dn, dlen);
    JS_FreeCString(ctx, dn);
    if (md is null) return throwTypeError(ctx, "unsupported digest");
    int hashLen = EVP_MD_get_size(md);
    if (hashLen <= 0 || keylen > 255 * hashLen) return throwRangeError(ctx, "HKDF output too long");
    Bytes ikm = void, salt = void, info = void;
    if (!bytesAcquire(ctx, argv[1], ikm)) return jsException();
    if (!bytesAcquire(ctx, argv[2], salt)) { bytesRelease(ctx, ikm); return jsException(); }
    if (!bytesAcquire(ctx, argv[3], info)) { bytesRelease(ctx, ikm); bytesRelease(ctx, salt); return jsException(); }
    scope(exit) { bytesRelease(ctx, ikm); bytesRelease(ctx, salt); bytesRelease(ctx, info); }

    HMAC_CTX* h = HMAC_CTX_new();
    if (h is null) return throwInternalError(ctx, "HMAC context failed");
    scope(exit) HMAC_CTX_free(h);
    ubyte* prk = cast(ubyte*) malloc(cast(size_t) hashLen);
    ubyte* t = cast(ubyte*) malloc(cast(size_t) hashLen);
    ubyte* outp = cast(ubyte*) malloc(cast(size_t) keylen);
    if (prk is null || t is null || outp is null)
    { if (prk !is null) free(prk); if (t !is null) free(t); if (outp !is null) free(outp); return throwInternalError(ctx, "out of memory"); }
    scope(exit) { free(prk); free(t); free(outp); }

    // HKDF-Extract: PRK = HMAC(salt, IKM)
    uint prkLen = cast(uint) hashLen;
    if (HMAC_Init_ex(h, salt.len ? salt.ptr : null, cast(int) salt.len, md, null) != 1
        || HMAC_Update(h, ikm.ptr, ikm.len) != 1
        || HMAC_Final(h, prk, &prkLen) != 1)
        return throwInternalError(ctx, "HKDF extract failed");

    // HKDF-Expand: T(i) = HMAC(PRK, T(i-1) || info || i)
    size_t done = 0, tLen = 0;
    ubyte counter = 1;
    while (done < cast(size_t) keylen)
    {
        if (HMAC_Init_ex(h, prk, cast(int) prkLen, md, null) != 1) return throwInternalError(ctx, "HKDF expand failed");
        if (tLen > 0 && HMAC_Update(h, t, tLen) != 1) return throwInternalError(ctx, "HKDF expand failed");
        if (info.len > 0 && HMAC_Update(h, info.ptr, info.len) != 1) return throwInternalError(ctx, "HKDF expand failed");
        if (HMAC_Update(h, &counter, 1) != 1) return throwInternalError(ctx, "HKDF expand failed");
        uint blockLen = cast(uint) hashLen;
        if (HMAC_Final(h, t, &blockLen) != 1) return throwInternalError(ctx, "HKDF expand failed");
        tLen = blockLen;
        size_t take = tLen < cast(size_t) keylen - done ? tLen : cast(size_t) keylen - done;
        import core.stdc.string : memcpy;
        memcpy(outp + done, t, take);
        done += take;
        counter += 1;
    }
    return JS_NewArrayBufferCopy(ctx, outp, cast(size_t) keylen);
}
extern(C) JSValue jsHkdf(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsHkdfImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsScryptImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 5) return throwTypeError(ctx, "scrypt requires (password, salt, keylen, N, r, p)");
    int keylen = 0; int N = 0, r = 0, p = 0;
    if (!toInt32(ctx, argv[2], &keylen) || keylen <= 0) return throwTypeError(ctx, "invalid key length");
    if (!toInt32(ctx, argv[3], &N) || N < 2) return throwTypeError(ctx, "invalid N");
    if (!toInt32(ctx, argv[4], &r) || r <= 0) return throwTypeError(ctx, "invalid r");
    if (argc > 5 && !toInt32(ctx, argv[5], &p)) return throwTypeError(ctx, "invalid p");
    if (p <= 0) p = 1;
    Bytes pass = void, salt = void;
    if (!bytesAcquire(ctx, argv[0], pass)) return jsException();
    if (!bytesAcquire(ctx, argv[1], salt)) { bytesRelease(ctx, pass); return jsException(); }
    scope(exit) { bytesRelease(ctx, pass); bytesRelease(ctx, salt); }
    ubyte* outp = cast(ubyte*) malloc(cast(size_t) keylen);
    if (outp is null) return throwInternalError(ctx, "out of memory");
    scope(exit) free(outp);
    if (EVP_PBE_scrypt(cast(const(char)*) pass.ptr, pass.len, salt.ptr, salt.len,
                       cast(ulong) N, cast(ulong) r, cast(ulong) p, 32 * 1024 * 1024, outp, cast(size_t) keylen) != 1)
        return throwInternalError(ctx, "scrypt failed");
    return JS_NewArrayBufferCopy(ctx, outp, cast(size_t) keylen);
}
extern(C) JSValue jsScrypt(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsScryptImpl(ctx, thisVal, argc, argv); }

private JSValue pkeyToPem(JSContext* ctx, EVP_PKEY* pkey, bool priv) @nogc nothrow
{
    BIO* bio = BIO_new(BIO_s_mem());
    if (bio is null)
        return throwInternalError(ctx, "out of memory");
    scope(exit) BIO_free(bio);
    int ok = priv
        ? PEM_write_bio_PrivateKey(bio, pkey, null, null, 0, null, null)
        : PEM_write_bio_PUBKEY(bio, pkey);
    if (ok != 1)
        return throwInternalError(ctx, "key export failed");
    char* data = null;
    long n = BIO_ctrl(bio, 3, 0, &data);
    if (n <= 0 || data is null)
        return throwInternalError(ctx, "key export failed");
    return JS_NewStringLen(ctx, data, cast(size_t) n);
}

private extern(C) JSValue jsGenerateKeyPairImpl(JSContext* ctx, JSValueConst, int argc,
                                                JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    if (argc < 3 || !jsIsString(argv[0]) || !jsIsString(argv[2]))
        return throwTypeError(ctx, "generateKeyPair(type, bits, curve) expects strings");
    const(char)* type = null;
    const(char)* curve = null;
    size_t tl = 0, cl = 0;
    if (!toStringView(ctx, argv[0], &type, &tl) || !toStringView(ctx, argv[2], &curve, &cl))
        return jsException();
    int bits = 2048;
    if (!toInt32(ctx, argv[1], &bits))
    {
        JS_FreeCString(ctx, type);
        JS_FreeCString(ctx, curve);
        return jsException();
    }
    // Key generation is uninterruptible native compute on the loop thread;
    // bound the modulus like Node's sanity range rather than accept INT_MAX.
    if (bits < 512 || bits > 16384)
    {
        JS_FreeCString(ctx, type);
        JS_FreeCString(ctx, curve);
        return throwRangeError(ctx, "unsupported modulus size");
    }
    char* typez = cast(char*) malloc(tl + 1);
    char* curvez = cast(char*) malloc(cl + 1);
    if (typez is null || curvez is null)
    {
        free(typez);
        free(curvez);
        JS_FreeCString(ctx, type);
        JS_FreeCString(ctx, curve);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(typez, type, tl + 1);
    memcpy(curvez, curve, cl + 1);
    JS_FreeCString(ctx, type);
    JS_FreeCString(ctx, curve);

    EVP_PKEY_CTX* pctx = null;
    EVP_PKEY* pkey = null;
    bool ok = false;
    if (strcmp(typez, "rsa") == 0)
    {
        RSA* rsa = RSA_new();
        BIGNUM* e = BN_new();
        if (rsa !is null && e !is null && BN_set_word(e, 65537) == 1 &&
            RSA_generate_key_ex(rsa, bits, e, null) == 1)
        {
            pkey = EVP_PKEY_new();
            if (pkey !is null && EVP_PKEY_assign(pkey, 6, rsa) == 1)
                ok = true;
            else
            {
                if (pkey !is null) EVP_PKEY_free(pkey);
                pkey = null;
                RSA_free(rsa);
            }
        }
        else if (rsa !is null)
            RSA_free(rsa);
        if (e !is null) BN_free(e);
    }
    else if (strcmp(typez, "ec") == 0)
    {
        int nid = 415;
        if (strcmp(curvez, "secp384r1") == 0 || strcmp(curvez, "P-384") == 0) nid = 715;
        else if (strcmp(curvez, "secp521r1") == 0 || strcmp(curvez, "P-521") == 0) nid = 716;
        EC_KEY* ec = EC_KEY_new_by_curve_name(nid);
        if (ec !is null && EC_KEY_generate_key(ec) == 1)
        {
            pkey = EVP_PKEY_new();
            if (pkey !is null && EVP_PKEY_assign(pkey, 408, ec) == 1)
                ok = true;
            else
            {
                if (pkey !is null) EVP_PKEY_free(pkey);
                pkey = null;
                EC_KEY_free(ec);
            }
        }
        else if (ec !is null)
            EC_KEY_free(ec);
    }
    else if (strcmp(typez, "ed25519") == 0)
    {
        pctx = EVP_PKEY_CTX_new_from_name(null, "ED25519", null);
        if (pctx !is null && EVP_PKEY_keygen_init(pctx) > 0)
            ok = EVP_PKEY_keygen(pctx, &pkey) == 1;
    }
    free(typez);
    free(curvez);
    if (pctx !is null) EVP_PKEY_CTX_free(pctx);
    if (!ok || pkey is null)
    {
        if (pkey !is null) EVP_PKEY_free(pkey);
        return throwInternalError(ctx, "key generation failed");
    }
    scope(exit) EVP_PKEY_free(pkey);
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return obj;
    JSValue priv = pkeyToPem(ctx, pkey, true);
    if (jsIsException(priv)) { JS_FreeValue(ctx, obj); return priv; }
    JSValue pub = pkeyToPem(ctx, pkey, false);
    if (jsIsException(pub)) { JS_FreeValue(ctx, priv); JS_FreeValue(ctx, obj); return pub; }
    JS_SetPropertyStr(ctx, obj, "privateKey", priv);
    JS_SetPropertyStr(ctx, obj, "publicKey", pub);
    return obj;
}

extern(C) JSValue jsGenerateKeyPair(JSContext* ctx, JSValueConst thisVal, int argc,
                                    JSValueConst* argv) nothrow @nogc
{
    return guarded!jsGenerateKeyPairImpl(ctx, thisVal, argc, argv);
}

private char* bioToString(BIO* bio) @nogc nothrow
{
    char* data = null;
    long n = BIO_ctrl(bio, 3, 0, &data);
    if (n <= 0 || data is null)
        return null;
    char* txt = cast(char*) malloc(cast(size_t) n + 1);
    if (txt is null)
        return null;
    memcpy(txt, data, cast(size_t) n);
    txt[n] = 0;
    return txt;
}

private extern(C) JSValue jsX509InfoImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    if (argc < 1 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "x509 expects a PEM string");
    const(char)* pem = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[0], &pem, &len))
        return jsException();
    BIO* bio = BIO_new_mem_buf(pem, cast(int) len);
    JS_FreeCString(ctx, pem);
    if (bio is null)
        return throwInternalError(ctx, "out of memory");
    scope(exit) BIO_free(bio);
    X509* cert = PEM_read_bio_X509(bio, null, null, null);
    if (cert is null)
        return throwInternalError(ctx, "invalid certificate");
    scope(exit) X509_free(cert);

    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return obj;

    char* subject = X509_NAME_oneline(X509_get_subject_name(cert), null, 0);
    char* issuer = X509_NAME_oneline(X509_get_issuer_name(cert), null, 0);
    if (subject !is null)
    {
        JS_SetPropertyStr(ctx, obj, "subject", newString(ctx, subject));
        CRYPTO_free(subject, null, 0);
    }
    if (issuer !is null)
    {
        JS_SetPropertyStr(ctx, obj, "issuer", newString(ctx, issuer));
        CRYPTO_free(issuer, null, 0);
    }

    BIO* dateBio = BIO_new(BIO_s_mem());
    if (dateBio !is null)
    {
        if (ASN1_TIME_print(dateBio, X509_get0_notBefore(cert)) == 1)
        {
            char* v = bioToString(dateBio);
            if (v !is null) { JS_SetPropertyStr(ctx, obj, "validFrom", newString(ctx, v)); free(v); }
        }
        BIO_free(dateBio);
        dateBio = BIO_new(BIO_s_mem());
        if (dateBio !is null && ASN1_TIME_print(dateBio, X509_get0_notAfter(cert)) == 1)
        {
            char* v = bioToString(dateBio);
            if (v !is null) { JS_SetPropertyStr(ctx, obj, "validTo", newString(ctx, v)); free(v); }
        }
        if (dateBio !is null) BIO_free(dateBio);
    }

    ubyte[64] md = void;
    uint mdLen = 0;
    if (X509_digest(cert, EVP_sha256(), &md[0], &mdLen) == 1)
    {
        static const(char)* hex = "0123456789abcdef";
        char* txt = cast(char*) malloc(mdLen * 3 + 1);
        if (txt !is null)
        {
            size_t o = 0;
            for (uint i = 0; i < mdLen; i++)
            {
                if (i) txt[o++] = ':';
                txt[o++] = hex[md[i] >> 4];
                txt[o++] = hex[md[i] & 0x0F];
            }
            txt[o] = 0;
            JS_SetPropertyStr(ctx, obj, "fingerprint256", newString(ctx, txt));
            free(txt);
        }
    }

    BIO* serialBio = BIO_new(BIO_s_mem());
    if (serialBio !is null)
    {
        if (i2a_ASN1_INTEGER(serialBio, X509_get_serialNumber(cert)) > 0)
        {
            char* v = bioToString(serialBio);
            if (v !is null) { JS_SetPropertyStr(ctx, obj, "serialNumber", newString(ctx, v)); free(v); }
        }
        BIO_free(serialBio);
    }
    return obj;
}

extern(C) JSValue jsX509Info(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{
    return guarded!jsX509InfoImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsX509CheckHostImpl(JSContext* ctx, JSValueConst, int argc,
                                              JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]) || !jsIsString(argv[1]))
        return throwTypeError(ctx, "x509CheckHost(pem, host) expects strings");
    const(char)* pem = null;
    const(char)* host = null;
    size_t pl = 0, hl = 0;
    if (!toStringView(ctx, argv[0], &pem, &pl) || !toStringView(ctx, argv[1], &host, &hl))
        return jsException();
    BIO* bio = BIO_new_mem_buf(pem, cast(int) pl);
    JS_FreeCString(ctx, pem);
    if (bio is null)
    {
        JS_FreeCString(ctx, host);
        return throwInternalError(ctx, "out of memory");
    }
    X509* cert = PEM_read_bio_X509(bio, null, null, null);
    BIO_free(bio);
    if (cert is null)
    {
        JS_FreeCString(ctx, host);
        return throwInternalError(ctx, "invalid certificate");
    }
    char* hostz = cast(char*) malloc(hl + 1);
    if (hostz is null)
    {
        X509_free(cert);
        JS_FreeCString(ctx, host);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(hostz, host, hl + 1);
    JS_FreeCString(ctx, host);
    int ok = X509_check_host(cert, hostz, hl, 0, null);
    free(hostz);
    X509_free(cert);
    return jsBool(ok == 1);
}

extern(C) JSValue jsX509CheckHost(JSContext* ctx, JSValueConst thisVal, int argc,
                                  JSValueConst* argv) nothrow @nogc
{
    return guarded!jsX509CheckHostImpl(ctx, thisVal, argc, argv);
}

bool installCrypto(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "createHash", &jsCryptoStart, 1)
        && addNativeFunction(ctx, obj, "createHmac", &jsCryptoStartHmac, 2)
        && addNativeFunction(ctx, obj, "update", &jsCryptoUpdate, 2)
        && addNativeFunction(ctx, obj, "digest", &jsCryptoDigest, 1)
        && addNativeFunction(ctx, obj, "randomBytes", &jsCryptoRandom, 1)
        && addNativeFunction(ctx, obj, "timingSafeEqual", &jsTimingSafeEqual, 2)
        && addNativeFunction(ctx, obj, "cipher", &jsCipher, 7)
        && addNativeFunction(ctx, obj, "pbkdf2", &jsPbkdf2, 5)
        && addNativeFunction(ctx, obj, "hkdf", &jsHkdf, 5)
        && addNativeFunction(ctx, obj, "scrypt", &jsScrypt, 5)
        && addNativeFunction(ctx, obj, "sign", &jsSign, 3)
        && addNativeFunction(ctx, obj, "verify", &jsVerify, 4)
        && addNativeFunction(ctx, obj, "generateKeyPair", &jsGenerateKeyPair, 3)
        && addNativeFunction(ctx, obj, "x509", &jsX509Info, 1)
        && addNativeFunction(ctx, obj, "x509CheckHost", &jsX509CheckHost, 2);
    if (!ok || JS_SetPropertyStr(ctx, djs, "crypto", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
