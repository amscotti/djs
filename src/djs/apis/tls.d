module djs.apis.tls;

// TLS client. The blocking TCP connect + TLS handshake run on a libuv worker
// thread; once the session is established the socket is non-blocking and all
// reads/writes happen on the loop thread through uv_poll. This keeps the loop
// free during DNS/connect/handshake without a second state machine for every
// WANT_READ/WANT_WRITE transition.

import core.stdc.errno : EINPROGRESS, EINTR, errno;
import core.sys.posix.fcntl : F_GETFL, F_SETFL, O_NONBLOCK, fcntl;
import core.stdc.stdlib : free, getenv, malloc;
import core.stdc.string : memcmp, memcpy, strlen;
import core.sys.posix.netdb : addrinfo, freeaddrinfo, getaddrinfo;
import core.sys.posix.arpa.inet : inet_pton;
import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
import core.sys.posix.sys.socket : AF_INET, AF_INET6, AF_UNSPEC, SO_ERROR, SOCK_STREAM, SOL_SOCKET,
    SO_TYPE, connect, getsockopt, setsockopt, socket, sockaddr, socklen_t;
import core.sys.posix.unistd : close;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.permissions : Perm, permissionCheck, permissionThrow;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;

private struct ssl_ctx_st;
private struct ssl_st;
private struct ssl_method_st;
private alias SSL_CTX = ssl_ctx_st;
private alias SSL = ssl_st;
private alias SSL_METHOD = ssl_method_st;

private enum int SSL_VERIFY_NONE = 0;
private enum int SSL_VERIFY_PEER = 1;
private enum int SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 2;
private enum int SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
private enum int SSL_CTRL_SET_VERIFY_CERT_STORE = 106; // ssl.h; larg=1 up-refs the store
private enum int TLSEXT_NAMETYPE_host_name = 0;
private enum long SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
private enum long TLS1_2_VERSION = 0x0303;
private enum int SSL_ERROR_WANT_READ = 2;
private enum int SSL_ERROR_WANT_WRITE = 3;
private enum int SSL_ERROR_ZERO_RETURN = 6;

extern(C) {
    const(SSL_METHOD)* TLS_client_method() nothrow @nogc;
    const(SSL_METHOD)* TLS_server_method() nothrow @nogc;
    SSL_CTX* SSL_CTX_new(const(SSL_METHOD)* meth) nothrow @nogc;
    void SSL_CTX_free(SSL_CTX*) nothrow @nogc;
    int SSL_CTX_set_default_verify_paths(SSL_CTX*) nothrow @nogc;
    void SSL_CTX_set_verify(SSL_CTX*, int mode, void* cb) nothrow @nogc;
    long SSL_CTX_ctrl(SSL_CTX*, int cmd, long larg, void* parg) nothrow @nogc;
    SSL* SSL_new(SSL_CTX*) nothrow @nogc;
    void SSL_free(SSL*) nothrow @nogc;
    int SSL_set_fd(SSL*, int fd) nothrow @nogc;
    long SSL_ctrl(SSL*, int cmd, long larg, void* parg) nothrow @nogc;
    int SSL_connect(SSL*) nothrow @nogc;
    int SSL_accept(SSL*) nothrow @nogc;
    int SSL_CTX_use_certificate_file(SSL_CTX*, const(char)* file, int type) nothrow @nogc;
    int SSL_CTX_load_verify_locations(SSL_CTX*, const(char)* cafile, const(char)* capath) nothrow @nogc;
    int SSL_CTX_set_alpn_protos(SSL_CTX*, const(ubyte)* protos, uint len) nothrow @nogc;
    int SSL_CTX_set_alpn_select_cb(SSL_CTX*, void* cb, void* arg) nothrow @nogc;
    void SSL_get0_alpn_selected(const(SSL)*, const(ubyte)** data, uint* len) nothrow @nogc;
    int SSL_CTX_use_PrivateKey_file(SSL_CTX*, const(char)* file, int type) nothrow @nogc;
    int SSL_CTX_check_private_key(const(SSL_CTX)*) nothrow @nogc;
    int SSL_get_error(const(SSL)*, int ret) nothrow @nogc;
    int SSL_read(SSL*, void* buf, int num) nothrow @nogc;
    int SSL_write(SSL*, const(void)* buf, int num) nothrow @nogc;
    int SSL_shutdown(SSL*) nothrow @nogc;
    long SSL_get_verify_result(const(SSL)*) nothrow @nogc;
    void* SSL_get1_peer_certificate(const(SSL)*) nothrow @nogc;
    void X509_free(void*) nothrow @nogc;
    const(char)* X509_verify_cert_error_string(long n) nothrow @nogc;
    ulong ERR_get_error() nothrow @nogc;
    void ERR_error_string_n(ulong e, char* buf, size_t len) nothrow @nogc;

    // Shared default CA store: built once at startup (default paths plus
    // NODE_EXTRA_CA_CERTS) and attached to every verifying client context,
    // so the CA bundle is not re-parsed per connection.
    void* X509_STORE_new() nothrow @nogc;
    int X509_STORE_set_default_paths(void* st) nothrow @nogc;
    int X509_STORE_load_locations(void* st, const(char)* file, const(char)* dir) nothrow @nogc;
    void X509_STORE_free(void* st) nothrow @nogc;
    // Peer certificate identity (hostname/SAN check, Node's
    // tls.checkServerIdentity behaviour).
    void* X509_get_subject_name(const(void)* x) nothrow @nogc;
    int X509_NAME_get_text_by_NID(void* name, int nid, char* buf, int len) nothrow @nogc;
    void* X509_get_ext_d2i(void* x, int nid, int* crit, int* idx) nothrow @nogc;
    void GENERAL_NAMES_free(void* st) nothrow @nogc;
    int OPENSSL_sk_num(const(void)* st) nothrow @nogc;
    void* OPENSSL_sk_value(const(void)* st, int i) nothrow @nogc;
}

private __gshared char[128] gAlpnPref;
private __gshared bool gAlpnHasPref;

// Minimal mirrors for certificate identity access. Both C structs are
// pointer-stable public ABI: ASN1_STRING is {int length; int type; char* data;
// long flags} and GENERAL_NAME is {int type; union of pointers}.
private struct Asn1StringRef
{
    int length;
    int type_;
    char* data;
    long flags_;
}
private struct GeneralNameRef
{
    int type_;
    void* value_; // all union members are pointers
}
private enum int NID_subject_alt_name = 85;
private enum int NID_commonName = 13;
private enum int GEN_DNS = 2;
private enum int GEN_IPADD = 7;

// Shared CA store states: 1 = ready, 2 = NODE_EXTRA_CA_CERTS failed to load,
// 0 = not built (connections fall back to per-context default paths).
private __gshared void* g_caStore;
private __gshared int g_caState;
private __gshared const(char)* g_caError;

private void buildSharedCaStore() @nogc nothrow
{
    void* st = X509_STORE_new();
    if (st is null)
        return; // state stays 0: connections use per-context default paths
    if (X509_STORE_set_default_paths(st) != 1)
    {
        X509_STORE_free(st);
        return;
    }
    const(char)* extra = getenv("NODE_EXTRA_CA_CERTS");
    if (extra !is null && extra[0] != 0 && X509_STORE_load_locations(st, extra, null) != 1)
    {
        X509_STORE_free(st);
        g_caState = 2;
        g_caError = "could not load NODE_EXTRA_CA_CERTS";
        return;
    }
    g_caStore = st;
    g_caState = 1;
}

// Runtime teardown, after the loop drain released every SSL_CTX that shared
// the store: drop the startup reference. Safe to call repeatedly.
void tlsFreeGlobals() @nogc nothrow
{
    if (g_caStore !is null)
    {
        X509_STORE_free(g_caStore);
        g_caStore = null;
    }
    g_caState = 0;
    g_caError = null;
}

// Node reports the OpenSSL verify-reason name (X509_V_ERR_* minus the prefix)
// as the error code. Generated from x509_vfy.h.
private const(char)* verifyCodeString(long vr) @nogc nothrow
{
    switch (vr)
    {
        case 1: return "UNSPECIFIED";
        case 2: return "UNABLE_TO_GET_ISSUER_CERT";
        case 3: return "UNABLE_TO_GET_CRL";
        case 4: return "UNABLE_TO_DECRYPT_CERT_SIGNATURE";
        case 5: return "UNABLE_TO_DECRYPT_CRL_SIGNATURE";
        case 6: return "UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY";
        case 7: return "CERT_SIGNATURE_FAILURE";
        case 8: return "CRL_SIGNATURE_FAILURE";
        case 9: return "CERT_NOT_YET_VALID";
        case 10: return "CERT_HAS_EXPIRED";
        case 11: return "CRL_NOT_YET_VALID";
        case 12: return "CRL_HAS_EXPIRED";
        case 13: return "ERROR_IN_CERT_NOT_BEFORE_FIELD";
        case 14: return "ERROR_IN_CERT_NOT_AFTER_FIELD";
        case 15: return "ERROR_IN_CRL_LAST_UPDATE_FIELD";
        case 16: return "ERROR_IN_CRL_NEXT_UPDATE_FIELD";
        case 17: return "OUT_OF_MEM";
        case 18: return "DEPTH_ZERO_SELF_SIGNED_CERT";
        case 19: return "SELF_SIGNED_CERT_IN_CHAIN";
        case 20: return "UNABLE_TO_GET_ISSUER_CERT_LOCALLY";
        case 21: return "UNABLE_TO_VERIFY_LEAF_SIGNATURE";
        case 22: return "CERT_CHAIN_TOO_LONG";
        case 23: return "CERT_REVOKED";
        case 24: return "NO_ISSUER_PUBLIC_KEY";
        case 25: return "PATH_LENGTH_EXCEEDED";
        case 26: return "INVALID_PURPOSE";
        case 27: return "CERT_UNTRUSTED";
        case 28: return "CERT_REJECTED";
        case 29: return "SUBJECT_ISSUER_MISMATCH";
        case 30: return "AKID_SKID_MISMATCH";
        case 31: return "AKID_ISSUER_SERIAL_MISMATCH";
        case 32: return "KEYUSAGE_NO_CERTSIGN";
        case 33: return "UNABLE_TO_GET_CRL_ISSUER";
        case 34: return "UNHANDLED_CRITICAL_EXTENSION";
        case 35: return "KEYUSAGE_NO_CRL_SIGN";
        case 36: return "UNHANDLED_CRITICAL_CRL_EXTENSION";
        case 37: return "INVALID_NON_CA";
        case 38: return "PROXY_PATH_LENGTH_EXCEEDED";
        case 39: return "KEYUSAGE_NO_DIGITAL_SIGNATURE";
        case 40: return "PROXY_CERTIFICATES_NOT_ALLOWED";
        case 41: return "INVALID_EXTENSION";
        case 42: return "INVALID_POLICY_EXTENSION";
        case 43: return "NO_EXPLICIT_POLICY";
        case 44: return "DIFFERENT_CRL_SCOPE";
        case 45: return "UNSUPPORTED_EXTENSION_FEATURE";
        default: return null; // unmapped: the generic ERR_TLS_HANDSHAKE is kept
    }
}

private extern(C) int alpnSelectCb(SSL*, const(ubyte)** outPtr, ubyte* outLen,
                                   const(ubyte)* inData, uint inLen, void*) nothrow @nogc
{
    if (!gAlpnHasPref) return 3;
    size_t prefLen = strlen(gAlpnPref.ptr);
    size_t p = 0;
    while (p < prefLen)
    {
        size_t pe = p;
        while (pe < prefLen && gAlpnPref[pe] != ',') pe += 1;
        size_t plen = pe - p;
        size_t off = 0;
        while (off + 1 <= inLen)
        {
            size_t clen = inData[off];
            if (clen == 0 || off + 1 + clen > inLen) break;
            if (clen == plen && memcmp(inData + off + 1, gAlpnPref.ptr + p, plen) == 0)
            {
                *outPtr = inData + off + 1;
                *outLen = cast(ubyte) clen;
                return 0;
            }
            off += 1 + clen;
        }
        p = pe + 1;
    }
    return 3;
}

private enum int maxTls = 16;
private enum int readChunk = 16384;
private enum size_t maxWriteQueue = 16 * 1024 * 1024;

private struct TlsSock
{
    bool used;
    bool closing;
    uint id;
    int fd;
    uv_poll_t* poll;
    Runtime* rt;
    SSL* ssl;
    SSL_CTX* ctx;
    ulong readCb;
    ulong writeCb;
    ubyte* wbuf;
    size_t wlen;
    size_t woff;
}

private TlsSock[maxTls] socks;
private uint nextId = 1;

private struct WorkJob
{
    uv_work_t* req;
    Runtime* rt;
    ulong cb;
    char* host;
    char* servername;
    char* caFile;
    char* certFile;
    char* keyFile;
    char* alpn;
    int port;
    bool verify;
    int fd;
    SSL* ssl;
    SSL_CTX* ctx;
    int err;
    char[512] msg;
    char[48] code; // error code override; empty = ERR_TLS_HANDSHAKE
}

private void setMsg(WorkJob* j, const(char)* text) @nogc nothrow
{
    size_t i = 0;
    if (text !is null)
        while (text[i] != 0 && i + 1 < j.msg.length) { j.msg[i] = text[i]; i += 1; }
    j.msg[i] = 0;
}

private void setCode(WorkJob* j, const(char)* text) @nogc nothrow
{
    size_t i = 0;
    if (text !is null)
        while (text[i] != 0 && i + 1 < j.code.length) { j.code[i] = text[i]; i += 1; }
    j.code[i] = 0;
}

private void tlsErrorMessage(WorkJob* j) @nogc nothrow
{
    ulong e = ERR_get_error();
    if (e != 0)
    {
        ERR_error_string_n(e, j.msg.ptr, j.msg.length);
        return;
    }
    setMsg(j, "TLS handshake failed");
}


private extern(C) int tlsVerifyContinueCb(int preverifyOk, void* x509Ctx) nothrow @nogc
{
    // Continue through every verification error so the final result is
    // available after the handshake; the mapped code is reported then. This
    // mirrors Node, which surfaces specific codes (self-signed, unknown CA,
    // expired) rather than a generic handshake failure.
    return 1;
}

private bool dnsNameMatches(const(char)* host, size_t hostLen,
                            const(char)* name, int nameLen) @nogc nothrow
{
    if (hostLen == 0 || nameLen <= 0)
        return false;
    char[256] h = void;
    char[256] n = void;
    if (hostLen >= h.length || cast(size_t) nameLen >= n.length)
        return false;
    for (size_t i = 0; i < hostLen; ++i)
        h[i] = (host[i] >= 'A' && host[i] <= 'Z') ? cast(char) (host[i] + 32) : host[i];
    for (int i = 0; i < nameLen; ++i)
        n[i] = (name[i] >= 'A' && name[i] <= 'Z') ? cast(char) (name[i] + 32) : name[i];
    size_t hl = hostLen;
    int nl = nameLen;
    // Exact match.
    if (hl == cast(size_t) nl)
    {
        bool same = true;
        for (size_t i = 0; i < hl; ++i)
            if (h[i] != n[i]) { same = false; break; }
        if (same) return true;
    }
    // Wildcard: "*." in the certificate matches exactly one leftmost label.
    if (nl > 2 && n[0] == '*' && n[1] == '.')
    {
        size_t hi = 0;
        while (hi < hl && h[hi] != '.') hi += 1;
        if (hi == hl || hi == 0) return false; // host must have another label
        size_t hRest = hi + 1;
        size_t nRest = 2;
        if (hl - hRest != cast(size_t) (nl - nRest)) return false;
        for (size_t i = 0; i < hl - hRest; ++i)
            if (h[hRest + i] != n[nRest + i]) return false;
        return true;
    }
    return false;
}

// Node's checkServerIdentity essentials: SANs win when present (DNS names
// case-insensitively with leftmost-label wildcards, IP addresses byte-wise);
// without SANs the CN is used. No identity at all is a mismatch.
private bool tlsHostMatches(const(char)* servername, SSL* ssl) @nogc nothrow
{
    if (servername is null || servername[0] == 0)
        return true; // nothing to check, like Node without a servername
    void* cert = SSL_get1_peer_certificate(ssl);
    if (cert is null)
        return true; // verified sessions always present one; defensive
    scope(exit) X509_free(cert);

    char[256] host = void;
    size_t hostLen = strlen(servername);
    if (hostLen >= host.length)
        return false;
    memcpy(host.ptr, servername, hostLen);
    if (hostLen > 0 && host[hostLen - 1] == '.')
        hostLen -= 1; // ignore one trailing dot, like Node
    host[hostLen] = 0;

    bool hostIsIp = false;
    int ipLen = 0;
    ubyte[16] ipBuf = void;
    if (inet_pton(AF_INET, host.ptr, ipBuf.ptr) == 1) { hostIsIp = true; ipLen = 4; }
    else if (inet_pton(AF_INET6, host.ptr, ipBuf.ptr) == 1) { hostIsIp = true; ipLen = 16; }

    void* sans = X509_get_ext_d2i(cert, NID_subject_alt_name, null, null);
    if (sans !is null)
    {
        scope(exit) GENERAL_NAMES_free(sans);
        int count = OPENSSL_sk_num(sans);
        for (int i = 0; i < count; ++i)
        {
            GeneralNameRef* gn = cast(GeneralNameRef*) OPENSSL_sk_value(sans, i);
            if (gn is null || gn.value_ is null) continue;
            Asn1StringRef* str = cast(Asn1StringRef*) gn.value_;
            if (gn.type_ == GEN_DNS && !hostIsIp)
            {
                if (str !is null && str.data !is null &&
                    dnsNameMatches(host.ptr, hostLen, str.data, str.length))
                    return true;
            }
            else if (gn.type_ == GEN_IPADD && hostIsIp)
            {
                if (str !is null && str.length == ipLen && str.data !is null &&
                    memcmp(str.data, ipBuf.ptr, cast(size_t) ipLen) == 0)
                    return true;
            }
        }
        return false; // SANs present: the CN is not consulted
    }
    char[256] cn = void;
    if (X509_NAME_get_text_by_NID(X509_get_subject_name(cert), NID_commonName,
                                  cn.ptr, cast(int) cn.length) > 0)
        return dnsNameMatches(host.ptr, hostLen, cn.ptr, cast(int) strlen(cn.ptr));
    return false;
}

private extern(C) void tlsWork(uv_work_t* req) nothrow @nogc
{
    WorkJob* j = cast(WorkJob*) uv_req_get_data(cast(uv_req_t*) req);
    if (j is null) return;
    char[16] portBuf = void;
    int n = 0, v = j.port;
    char[16] tmp = void;
    do { tmp[n] = cast(char)('0' + v % 10); v /= 10; n += 1; } while (v > 0 && n < 15);
    for (int i = 0; i < n; ++i) portBuf[i] = tmp[n - 1 - i];
    portBuf[n] = 0;

    addrinfo hints = addrinfo.init;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = null;
    if (getaddrinfo(j.host, portBuf.ptr, &hints, &res) != 0 || res is null)
    {
        setMsg(j, "getaddrinfo failed");
        j.err = 1;
        return;
    }
    scope(exit) freeaddrinfo(res);
    int fd = -1;
    for (addrinfo* ai = res; ai !is null; ai = ai.ai_next)
    {
        fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
        if (fd < 0) continue;
        int flags0 = fcntl(fd, F_GETFL, 0);
        if (flags0 >= 0) fcntl(fd, F_SETFL, flags0 | O_NONBLOCK);
        int rc = connect(fd, ai.ai_addr, ai.ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS)
        {
            pollfd p = void;
            p.fd = fd;
            p.events = POLLOUT;
            if (poll(&p, 1, 10000) > 0)
            {
                int soerr = 0;
                socklen_t slen = socklen_t.sizeof;
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0 && soerr == 0)
                    rc = 0;
            }
        }
        if (rc == 0) break;
        close(fd);
        fd = -1;
    }
    if (fd < 0)
    {
        setMsg(j, "connect failed");
        j.err = 1;
        return;
    }
    j.fd = fd;
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (ctx is null) { setMsg(j, "SSL_CTX_new failed"); j.err = 1; return; }
    j.ctx = ctx;
    SSL_CTX_ctrl(ctx, cast(int) SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);
    if (j.verify)
    {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, &tlsVerifyContinueCb);
        if (j.caFile !is null)
        {
            // An explicit ca option overrides the default store, as in Node.
            if (SSL_CTX_load_verify_locations(ctx, j.caFile, null) != 1)
            {
                setMsg(j, "could not load CA file");
                j.err = 1;
                return;
            }
        }
        else if (g_caState == 2)
        {
            setMsg(j, g_caError);
            j.err = 1;
            return;
        }
        else if (g_caStore !is null &&
                 SSL_CTX_ctrl(ctx, SSL_CTRL_SET_VERIFY_CERT_STORE, 1, g_caStore) == 1)
        {
            // Shared store: default paths plus NODE_EXTRA_CA_CERTS (built
            // once at startup). SSL_CERT_FILE/SSL_CERT_DIR are honoured by
            // OpenSSL's default-path loading either way.
        }
        else
            SSL_CTX_set_default_verify_paths(ctx);
    }
    if (j.certFile !is null || j.keyFile !is null)
    {
        if (j.certFile is null || j.keyFile is null ||
            SSL_CTX_use_certificate_file(ctx, j.certFile, SSL_FILETYPE_PEM) != 1 ||
            SSL_CTX_use_PrivateKey_file(ctx, j.keyFile, SSL_FILETYPE_PEM) != 1 ||
            SSL_CTX_check_private_key(ctx) != 1)
        {
            setMsg(j, "invalid client certificate or key");
            j.err = 1;
            return;
        }
    }
    if (j.alpn !is null)
    {
        ubyte[256] protos = void;
        size_t used = 0;
        size_t start = 0;
        size_t i = 0;
        while (i <= strlen(j.alpn) && used + 1 < protos.length)
        {
            if (j.alpn[i] == ',' || j.alpn[i] == 0)
            {
                size_t plen = i - start;
                if (plen > 0 && plen < 256)
                {
                    protos[used] = cast(ubyte) plen;
                    memcpy(protos.ptr + used + 1, j.alpn + start, plen);
                    used += plen + 1;
                }
                start = i + 1;
                if (j.alpn[i] == 0) break;
            }
            i += 1;
        }
        if (used > 0 && SSL_CTX_set_alpn_protos(ctx, protos.ptr, cast(uint) used) != 0)
        {
            setMsg(j, "could not set ALPN protocols");
            j.err = 1;
            return;
        }
    }
    // Verification mode is set only by the `if (j.verify)` block above:
    // SSL_VERIFY_PEER when verifying, and OpenSSL's default (VERIFY_NONE)
    // otherwise. Do not touch it here — an `else` on the ALPN branch used to
    // reset VERIFY_PEER for every connection without an ALPN list.
    SSL* ssl = SSL_new(ctx);
    if (ssl is null) { setMsg(j, "SSL_new failed"); j.err = 1; return; }
    j.ssl = ssl;
    SSL_set_fd(ssl, fd);
    // SNI is not sent for IP literals (Node does the same). Hostname
    // matching happens after the handshake, in tlsHostMatches.
    char sni0 = j.servername !is null ? j.servername[0] : 0;
    bool servernameIsIp = (sni0 >= '0' && sni0 <= '9') || sni0 == ':';
    if (!servernameIsIp && sni0 != 0)
        SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name,
                 cast(void*) j.servername);
    while (true)
    {
        int rc = SSL_connect(ssl);
        if (rc == 1) break;
        int e = SSL_get_error(ssl, rc);
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
        {
            pollfd p = void;
            p.fd = fd;
            p.events = e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
            if (poll(&p, 1, 10000) > 0) continue;
            setMsg(j, "TLS handshake timed out");
            j.err = 1;
            return;
        }
        tlsErrorMessage(j);
        j.err = 1;
        return;
    }
    if (j.verify)
    {
        long vr = SSL_get_verify_result(ssl);
        if (vr != 0)
        {
            setMsg(j, X509_verify_cert_error_string(vr));
            setCode(j, verifyCodeString(vr));
            j.err = 1;
            return;
        }
        if (!tlsHostMatches(j.servername, ssl))
        {
            setMsg(j, "Hostname/IP does not match certificate's altnames");
            setCode(j, "ERR_TLS_CERT_ALTNAME_INVALID");
            j.err = 1;
            return;
        }
    }
    // The handshake ran on a blocking socket; the loop's SSL_read/SSL_write
    // paths require non-blocking descriptors or a slow peer can stall the loop.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    j.err = 0;
}

private extern(C) void tlsHandleClose(uv_handle_t* h) nothrow @nogc { free(h); }

private TlsSock* findSock(uint id) @nogc nothrow
{
    foreach (ref s; socks)
        if (s.used && s.id == id)
            return &s;
    return null;
}

private void releaseSock(TlsSock* s) @nogc nothrow
{
    if (s is null) return;
    // Callback slots hold a JSValue each; releasing them is what keeps the
    // QuickJS heap flat when a socket is closed without delivering EOF.
    if (s.readCb != 0 && s.rt !is null)
        registryRelease(s.rt.ctx, &s.rt.registry, s.readCb);
    if (s.writeCb != 0 && s.rt !is null)
        registryRelease(s.rt.ctx, &s.rt.registry, s.writeCb);
    if (s.poll !is null)
    {
        uv_poll_stop(s.poll);
        uv_close(cast(uv_handle_t*) s.poll, &tlsHandleClose);
        s.poll = null;
    }
    if (s.ssl !is null) { SSL_shutdown(s.ssl); SSL_free(s.ssl); s.ssl = null; }
    if (s.ctx !is null) { SSL_CTX_free(s.ctx); s.ctx = null; }
    if (s.fd >= 0) { close(s.fd); s.fd = -1; }
    if (s.wbuf !is null) { free(s.wbuf); s.wbuf = null; }
    s.wlen = s.woff = 0;
    s.used = false;
    s.closing = false;
    s.readCb = 0;
    s.writeCb = 0;
    s.id = 0;
}

private void tlsCall(Runtime* rt, ulong cb, JSValue* argv, int argc,
                     bool release = false) @nogc nothrow
{
    if (rt !is null && cb != 0)
    {
        CallbackSlot* slot = registryLookup(&rt.registry, cb);
        if (slot !is null)
        {
            JSValue fn = JS_DupValue(rt.ctx, slot.fn);
            JSValue r = JS_Call(rt.ctx, fn, jsUndefined(), argc, argv);
            JS_FreeValue(rt.ctx, fn);
            if (jsIsException(r)) { JS_FreeValue(rt.ctx, r); runtimeReportUncaught(rt, rt.ctx); }
            else JS_FreeValue(rt.ctx, r);
            // One-shot callbacks (connect, single write, final read) release
            // their slot here; the registry's generation check makes a
            // later release of the same id a no-op, not a double free.
            if (release)
                registryRelease(rt.ctx, &rt.registry, cb);
        }
    }
    // Callers hand ownership of every argument to tlsCall; JS_Call borrows.
    if (rt !is null)
        for (int i = 0; i < argc; ++i)
            JS_FreeValue(rt.ctx, argv[i]);
}

private void flushWrites(TlsSock* s) @nogc nothrow
{
    if (s.wbuf is null || s.woff >= s.wlen) return;
    while (s.woff < s.wlen)
    {
        int n = SSL_write(s.ssl, s.wbuf + s.woff, cast(int)(s.wlen - s.woff));
        if (n > 0) { s.woff += cast(size_t) n; continue; }
        int e = SSL_get_error(s.ssl, n);
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return;
        ulong cb = s.writeCb;
        s.writeCb = 0;
        free(s.wbuf);
        s.wbuf = null;
        s.wlen = s.woff = 0;
        if (cb != 0)
        {
            JSValue err = makeError(s.rt.ctx, "TLS write failed", "ERR_TLS_WRITE", null, null);
            JSValue[1] argv = [err];
            tlsCall(s.rt, cb, argv.ptr, 1, true);
        }
        return;
    }
    ulong cb = s.writeCb;
    s.writeCb = 0;
    free(s.wbuf);
    s.wbuf = null;
    s.wlen = s.woff = 0;
    if (cb != 0)
    {
        JSValue[1] argv = [jsNull()];
        tlsCall(s.rt, cb, argv.ptr, 1, true);
    }
}

private extern(C) void tlsPollCb(uv_poll_t* h, int status, int events) nothrow @nogc
{
    TlsSock* s = cast(TlsSock*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (s is null || !s.used || s.closing) return;
    if ((events & UV_WRITABLE) != 0 && s.wbuf !is null)
        flushWrites(s);
    if (s.readCb == 0 || (events & UV_READABLE) == 0) return;
    ubyte[readChunk] buf = void;
    int n = SSL_read(s.ssl, buf.ptr, readChunk);
    if (n > 0)
    {
        JSValue chunk = JS_NewArrayBufferCopy(s.rt.ctx, buf.ptr, cast(size_t) n);
        JSValue[2] argv = [jsNull(), chunk];
        tlsCall(s.rt, s.readCb, argv.ptr, 2);
        return;
    }
    int e = SSL_get_error(s.ssl, n);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return;
    JSValue[2] argv = [jsNull(), jsNull()];
    tlsCall(s.rt, s.readCb, argv.ptr, 2, true);
    s.readCb = 0;
}

private void freeJob(WorkJob* j) @nogc nothrow
{
    if (j is null) return;
    if (j.cb != 0 && j.rt !is null)
        registryRelease(j.rt.ctx, &j.rt.registry, j.cb);
    if (j.host !is null) free(j.host);
    if (j.servername !is null) free(j.servername);
    if (j.caFile !is null) free(j.caFile);
    if (j.certFile !is null) free(j.certFile);
    if (j.keyFile !is null) free(j.keyFile);
    if (j.alpn !is null) free(j.alpn);
    free(j.req);
    free(j);
}

private extern(C) void tlsAfterWork(uv_work_t* req, int status) nothrow @nogc
{
    WorkJob* j = cast(WorkJob*) uv_req_get_data(cast(uv_req_t*) req);
    if (j is null) return;
    Runtime* rt = j.rt;
    if (j.err != 0 || j.ssl is null)
    {
        if (j.fd >= 0) close(j.fd);
        if (j.ssl !is null) SSL_free(j.ssl);
        if (j.ctx !is null) SSL_CTX_free(j.ctx);
        JSValue err = makeError(rt.ctx, j.msg[0] != 0 ? j.msg.ptr : "TLS failed",
                                j.code[0] != 0 ? j.code.ptr : "ERR_TLS_HANDSHAKE", null, null);
        JSValue[2] argv = [err, jsUndefined()];
        tlsCall(rt, j.cb, argv.ptr, 2, true);
        freeJob(j);
        return;
    }
    int slot = -1;
    foreach (i; 0 .. maxTls) if (!socks[i].used) { slot = cast(int) i; break; }
    if (slot < 0)
    {
        close(j.fd);
        SSL_free(j.ssl);
        SSL_CTX_free(j.ctx);
        JSValue err = makeError(rt.ctx, "TLS table exhausted", "ERR_TLS_EXHAUSTED", null, null);
        JSValue[2] argv = [err, jsUndefined()];
        tlsCall(rt, j.cb, argv.ptr, 2, true);
        freeJob(j);
        return;
    }
    TlsSock* s = &socks[slot];
    s.used = true;
    s.fd = j.fd;
    s.ssl = j.ssl;
    s.ctx = j.ctx;
    s.rt = rt;
    s.id = nextId++;
    if (nextId == 0) nextId = 1;
    uv_poll_t* p = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
    if (p is null || uv_poll_init_socket(rt.loop, p, j.fd) != 0)
    {
        if (p !is null) free(p);
        s.used = true;   // releaseSock requires a used slot to clean up
        releaseSock(s);
        JSValue err = makeError(rt.ctx, "TLS poll init failed", "ERR_TLS_INIT", null, null);
        JSValue[2] argv = [err, jsUndefined()];
        tlsCall(rt, j.cb, argv.ptr, 2, true);
        freeJob(j);
        return;
    }
    s.poll = p;
    uv_handle_set_data(cast(uv_handle_t*) p, s);
    uv_poll_start(p, UV_READABLE | UV_WRITABLE, &tlsPollCb);
    JSValue[2] argv = [jsNull(), jsInt(cast(int) s.id)];
    tlsCall(rt, j.cb, argv.ptr, 2, true);
    freeJob(j);
}

private char* dupOptString(JSContext* ctx, JSValueConst obj, const(char)* name) @nogc nothrow
{
    JSValue v = JS_GetPropertyStr(ctx, obj, name);
    if (!jsIsString(v)) { JS_FreeValue(ctx, v); return null; }
    const(char)* p = JS_ToCStringLen2(ctx, null, v, false);
    JS_FreeValue(ctx, v);
    if (p is null) return null;
    char* d = dupCString(p);
    JS_FreeCString(ctx, p);
    return d;
}

private extern(C) JSValue jsTlsConnectImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    if (argc < 5 || !jsIsString(argv[0]) || !jsIsString(argv[2]) || !JS_IsFunction(ctx, argv[4]))
        return throwTypeError(ctx, "tls.connect requires (host, port, servername, verify, callback)");
    int port = 0;
    if (!toInt32(ctx, argv[1], &port) || port <= 0 || port > 65535)
        return throwRangeError(ctx, "invalid port");
    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");
    const(char)* host = null;
    size_t hlen = 0;
    if (!toStringView(ctx, argv[0], &host, &hlen)) return jsException();
    const(char)* sni = null;
    size_t slen = 0;
    if (!toStringView(ctx, argv[2], &sni, &slen)) { JS_FreeCString(ctx, host); return jsException(); }
    // Outbound TLS is gated exactly like net.connect: host:port checked
    // before any DNS query or socket is made. __djs.tls.connect is
    // reachable from user code, so the check must live here, in native.
    char[320] netRes = void;
    {
        import core.stdc.stdio : snprintf;
        int rn = snprintf(netRes.ptr, netRes.length, "%.*s:%d",
                          cast(int) hlen, host, port);
        if (rn <= 0 || cast(size_t) rn >= netRes.length)
        {
            JS_FreeCString(ctx, host);
            JS_FreeCString(ctx, sni);
            return throwRangeError(ctx, "host too long");
        }
    }
    if (!permissionCheck(Perm.net, netRes.ptr))
    {
        JSValue e = permissionThrow(ctx, Perm.net, netRes.ptr);
        JS_FreeCString(ctx, host);
        JS_FreeCString(ctx, sni);
        return e;
    }
    char* caOpt = null;
    char* certOpt = null;
    char* keyOpt = null;
    char* alpnOpt = null;
    if (argc > 5 && jsIsObject(argv[5]))
    {
        caOpt = dupOptString(ctx, argv[5], "caFile");
        if (caOpt is null) caOpt = dupOptString(ctx, argv[5], "ca");
        certOpt = dupOptString(ctx, argv[5], "certFile");
        if (certOpt is null) certOpt = dupOptString(ctx, argv[5], "cert");
        keyOpt = dupOptString(ctx, argv[5], "keyFile");
        if (keyOpt is null) keyOpt = dupOptString(ctx, argv[5], "key");
        alpnOpt = dupOptString(ctx, argv[5], "alpn");
    }
    WorkJob* j = cast(WorkJob*) malloc(WorkJob.sizeof);
    if (j is null)
    {
        JS_FreeCString(ctx, host); JS_FreeCString(ctx, sni);
        free(caOpt); free(certOpt); free(keyOpt); free(alpnOpt);
        return throwInternalError(ctx, "out of memory");
    }
    *j = WorkJob.init;
    // char.init is 0xFF in D, not 0: terminate the buffers that are only
    // written on some paths so the empty checks in tlsAfterWork hold.
    j.msg[0] = 0;
    j.code[0] = 0;
    j.host = dupCString(host);
    j.servername = dupCString(sni);
    JS_FreeCString(ctx, host);
    JS_FreeCString(ctx, sni);
    if (j.host is null || j.servername is null)
    {
        if (j.host !is null) free(j.host);
        if (j.servername !is null) free(j.servername);
        free(caOpt); free(certOpt); free(keyOpt); free(alpnOpt);
        free(j);
        return throwInternalError(ctx, "out of memory");
    }
    j.caFile = caOpt; j.certFile = certOpt; j.keyFile = keyOpt; j.alpn = alpnOpt;
    j.rt = rt;
    j.port = port;
    j.verify = JS_ToBool(ctx, argv[3]) > 0;
    j.fd = -1;
    j.cb = registryAdd(ctx, &rt.registry, argv[4], null);
    if (j.cb == 0)
    {
        free(j.host); free(j.servername); free(j);
        free(j.caFile); free(j.certFile); free(j.keyFile); free(j.alpn);
        return throwInternalError(ctx, "out of memory");
    }
    j.req = cast(uv_work_t*) malloc(uv_req_size(UV_WORK));
    if (j.req is null)
    {
        registryRelease(ctx, &rt.registry, j.cb);
        free(j.host); free(j.servername); free(j);
        return throwInternalError(ctx, "out of memory");
    }
    uv_req_set_data(cast(uv_req_t*) j.req, j);
    if (uv_queue_work(rt.loop, j.req, &tlsWork, &tlsAfterWork) != 0)
    {
        registryRelease(ctx, &rt.registry, j.cb);
        free(j.req); free(j.host); free(j.servername);
        free(j.caFile); free(j.certFile); free(j.keyFile); free(j.alpn); free(j);
        return throwInternalError(ctx, "could not queue TLS work");
    }
    return jsUndefined();
}
extern(C) JSValue jsTlsConnect(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsConnectImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsPeerAuthorizedImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId)) return jsBool(false);
    TlsSock* s = findSock(cast(uint) rawId);
    if (s is null || s.ssl is null) return jsBool(false);
    if (SSL_get_verify_result(s.ssl) != 0) return jsBool(false);
    void* cert = SSL_get1_peer_certificate(s.ssl);
    if (cert is null) return jsBool(false);
    X509_free(cert);
    return jsBool(true);
}
extern(C) JSValue jsTlsPeerAuthorized(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsPeerAuthorizedImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsAlpnImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId)) return jsNull();
    TlsSock* s = findSock(cast(uint) rawId);
    if (s is null || s.ssl is null) return jsNull();
    const(ubyte)* data = null;
    uint len = 0;
    SSL_get0_alpn_selected(s.ssl, &data, &len);
    if (data is null || len == 0) return jsNull();
    return JS_NewStringLen(ctx, cast(const(char)*) data, len);
}
extern(C) JSValue jsTlsAlpn(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsAlpnImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsStartReadImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &rawId) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "tls.startRead requires (id, callback)");
    TlsSock* s = findSock(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid TLS handle");
    if (s.readCb != 0) registryRelease(ctx, &s.rt.registry, s.readCb);
    s.readCb = registryAdd(ctx, &s.rt.registry, argv[1], null);
    return jsUndefined();
}
extern(C) JSValue jsTlsStartRead(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsStartReadImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsWriteImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "tls.write requires (id, data)");
    TlsSock* s = findSock(cast(uint) rawId);
    if (s is null) return throwTypeError(ctx, "invalid TLS handle");
    const(char)* cstr = null;
    const(ubyte)* data = null;
    size_t len = 0;
    JSValue holder = jsUndefined();
    if (jsIsString(argv[1]) && toStringView(ctx, argv[1], &cstr, &len))
        data = cast(const(ubyte)*) cstr;
    else if (JS_IsArrayBuffer(argv[1]))
    {
        size_t size = 0;
        ubyte* p = JS_GetArrayBuffer(ctx, &size, argv[1]);
        if (p is null) return throwTypeError(ctx, "TLS writes require bytes");
        data = p; len = size;
        holder = JS_DupValue(ctx, argv[1]);
    }
    else
    {
        size_t off = 0, n = 0, bpe = 0;
        JSValue ab = JS_GetTypedArrayBuffer(ctx, argv[1], &off, &n, &bpe);
        if (jsIsException(ab)) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "TLS writes require bytes"); }
        size_t size = 0;
        ubyte* p = JS_GetArrayBuffer(ctx, &size, ab);
        if (p is null || off > size || n > size - off) { JS_FreeValue(ctx, ab); return throwTypeError(ctx, "TLS writes require bytes"); }
        data = p + off; len = n;
        holder = ab;
    }
    scope(exit) {
        if (cstr !is null) JS_FreeCString(ctx, cstr);
        if (!jsIsUndefined(holder)) JS_FreeValue(ctx, holder);
    }
    if (s.wlen - s.woff + len > maxWriteQueue)
        return throwRangeError(ctx, "TLS write queue limit exceeded");
    if (s.wbuf is null)
    {
        s.wbuf = cast(ubyte*) malloc(len);
        if (s.wbuf is null) return throwInternalError(ctx, "out of memory");
        memcpy(s.wbuf, data, len);
        s.wlen = len;
        s.woff = 0;
    }
    else
    {
        size_t pending = s.wlen - s.woff;
        ubyte* p = cast(ubyte*) malloc(pending + len);
        if (p is null) return throwInternalError(ctx, "out of memory");
        memcpy(p, s.wbuf + s.woff, pending);
        memcpy(p + pending, data, len);
        free(s.wbuf);
        s.wbuf = p;
        s.wlen = pending + len;
        s.woff = 0;
    }
    if (argc >= 3 && JS_IsFunction(ctx, argv[2]))
    {
        if (s.writeCb != 0) registryRelease(ctx, &s.rt.registry, s.writeCb);
        s.writeCb = registryAdd(ctx, &s.rt.registry, argv[2], null);
    }
    flushWrites(s);
    return jsUndefined();
}
extern(C) JSValue jsTlsWrite(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsWriteImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsEndImpl(JSContext* ctx, JSValueConst, int argc,
                                       JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "tls.end requires an id");
    TlsSock* s = findSock(cast(uint) rawId);
    if (s is null) return jsUndefined();
    flushWrites(s);
    if (s.wbuf is null) SSL_shutdown(s.ssl);
    return jsUndefined();
}
extern(C) JSValue jsTlsEnd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsEndImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsTlsCloseImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int rawId = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &rawId))
        return throwTypeError(ctx, "tls.close requires an id");
    TlsSock* s = findSock(cast(uint) rawId);
    if (s !is null) releaseSock(s);
    return jsUndefined();
}
extern(C) JSValue jsTlsClose(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsTlsCloseImpl(ctx, thisVal, argc, argv); }

void tlsCloseAll(Runtime* self) @nogc nothrow
{
    foreach (ref s; socks)
        if (s.used && s.rt is self)
            releaseSock(&s);
}


private enum int SSL_FILETYPE_PEM = 1;

private extern(C) JSValue jsAcceptFdImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    int fd = -1;
    if (argc < 3 || !toInt32(ctx, argv[0], &fd) || fd < 0)
        return throwTypeError(ctx, "acceptFd requires (fd, cert, key)");
    // The descriptor must be a socket: fd 0/1/2 (or any unrelated file)
    // would otherwise run a "handshake" over stdio and get closed on us.
    {
        int soType = 0;
        socklen_t soLen = cast(socklen_t) int.sizeof;
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &soType, &soLen) != 0)
            return throwTypeError(ctx, "acceptFd requires a socket fd");
    }
    const(char)* cert = null;
    size_t clen = 0;
    if (!toStringView(ctx, argv[1], &cert, &clen)) return jsException();
    const(char)* key = null;
    size_t klen = 0;
    if (!toStringView(ctx, argv[2], &key, &klen)) { JS_FreeCString(ctx, cert); return jsException(); }
    char* caOpt = null;
    bool requestCert = false;
    if (argc > 3 && jsIsObject(argv[3]))
    {
        caOpt = dupOptString(ctx, argv[3], "caFile");
        if (caOpt is null) caOpt = dupOptString(ctx, argv[3], "ca");
        JSValue rcv = JS_GetPropertyStr(ctx, argv[3], "requestCert");
        requestCert = JS_ToBool(ctx, rcv) > 0;
        JS_FreeValue(ctx, rcv);
        char* alpnPref = dupOptString(ctx, argv[3], "alpn");
        if (alpnPref !is null)
        {
            size_t alen = strlen(alpnPref);
            if (alen >= gAlpnPref.length) alen = gAlpnPref.length - 1;
            memcpy(gAlpnPref.ptr, alpnPref, alen);
            gAlpnPref[alen] = 0;
            gAlpnHasPref = alen > 0;
            free(alpnPref);
        }
    }
    scope(exit) { JS_FreeCString(ctx, cert); JS_FreeCString(ctx, key); free(caOpt); }
    if (!permissionCheck(Perm.read, cert))
        return permissionThrow(ctx, Perm.read, cert);
    if (!permissionCheck(Perm.read, key))
        return permissionThrow(ctx, Perm.read, key);
    SSL_CTX* sctx = SSL_CTX_new(TLS_server_method());
    if (sctx is null)
    {
        close(fd);
        return throwInternalError(ctx, "SSL_CTX_new failed");
    }
    SSL_CTX_ctrl(sctx, cast(int) SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);
    SSL_CTX_set_alpn_select_cb(sctx, cast(void*) &alpnSelectCb, null);
    if (caOpt !is null)
    {
        if (SSL_CTX_load_verify_locations(sctx, caOpt, null) != 1)
        {
            SSL_CTX_free(sctx);
            close(fd);
            return throwError(ctx, makeError(ctx, "could not load CA file", "ERR_TLS_INVALID_CA", caOpt, "tls"));
        }
        int mode = SSL_VERIFY_PEER;
        if (requestCert) mode |= SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
        SSL_CTX_set_verify(sctx, mode, null);
    }
    else
        SSL_CTX_set_verify(sctx, SSL_VERIFY_NONE, null);
    if (SSL_CTX_use_certificate_file(sctx, cert, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_use_PrivateKey_file(sctx, key, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_check_private_key(sctx) != 1)
    {
        SSL_CTX_free(sctx);
        close(fd);
        return throwError(ctx, makeError(ctx, "invalid certificate or key", "ERR_TLS_INVALID_CERT", null, "tls"));
    }
    SSL* ssl = SSL_new(sctx);
    if (ssl is null)
    {
        SSL_CTX_free(sctx);
        close(fd);
        return throwInternalError(ctx, "SSL_new failed");
    }
    SSL_set_fd(ssl, fd);
    // The handshake runs on the loop thread; a total deadline bounds how
    // long one stalling client can freeze every timer and I/O event. The
    // per-call poll timeout stays, but the loop as a whole is capped.
    ulong deadline = uv_hrtime() + 10_000_000_000UL; // 10 s
    while (true)
    {
        int rc = SSL_accept(ssl);
        if (rc == 1) break;
        int e = SSL_get_error(ssl, rc);
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE)
        {
            if (uv_hrtime() >= deadline)
            {
                SSL_free(ssl); SSL_CTX_free(sctx); close(fd);
                return throwError(ctx, makeError(ctx, "TLS handshake timed out", "ETIMEDOUT", null, "tls"));
            }
            pollfd p = void;
            p.fd = fd;
            p.events = e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
            // Never wait past the deadline.
            long leftMs = cast(long) ((deadline - uv_hrtime()) / 1_000_000);
            if (leftMs <= 0) leftMs = 1;
            if (leftMs > 10000) leftMs = 10000;
            if (poll(&p, 1, cast(int) leftMs) > 0) continue;
            SSL_free(ssl); SSL_CTX_free(sctx); close(fd);
            return throwError(ctx, makeError(ctx, "TLS handshake timed out", "ETIMEDOUT", null, "tls"));
        }
        SSL_free(ssl); SSL_CTX_free(sctx); close(fd);
        return throwError(ctx, makeError(ctx, "TLS handshake failed", "ERR_TLS_HANDSHAKE", null, "tls"));
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int slot = -1;
    foreach (i; 0 .. maxTls) if (!socks[i].used) { slot = cast(int) i; break; }
    if (slot < 0)
    {
        SSL_free(ssl); SSL_CTX_free(sctx); close(fd);
        return throwInternalError(ctx, "too many TLS sockets");
    }
    TlsSock* t = &socks[slot];
    *t = TlsSock.init;
    t.used = true;
    t.id = nextId++;
    if (nextId == 0) nextId = 1;
    t.fd = fd;
    t.ssl = ssl;
    t.ctx = sctx;
    Runtime* rt = runtimeOf(ctx);
    t.rt = rt;
    uv_poll_t* p = cast(uv_poll_t*) malloc(uv_handle_size(UV_POLL));
    if (p is null || uv_poll_init_socket(rt.loop, p, fd) != 0)
    {
        if (p !is null) free(p);
        t.used = true;
        releaseSock(t);
        return throwInternalError(ctx, "TLS poll init failed");
    }
    t.poll = p;
    uv_handle_set_data(cast(uv_handle_t*) p, t);
    uv_poll_start(p, UV_READABLE | UV_WRITABLE, &tlsPollCb);
    return jsInt(cast(int) t.id);
}
extern(C) JSValue jsAcceptFd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsAcceptFdImpl(ctx, thisVal, argc, argv); }

bool installTls(Runtime* self, JSValueConst djs) @nogc nothrow
{
    // Before the loop starts (single-threaded): build the shared CA store.
    buildSharedCaStore();
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "connect", &jsTlsConnect, 5)
        && addNativeFunction(ctx, obj, "startRead", &jsTlsStartRead, 2)
        && addNativeFunction(ctx, obj, "write", &jsTlsWrite, 3)
        && addNativeFunction(ctx, obj, "end", &jsTlsEnd, 1)
        && addNativeFunction(ctx, obj, "close", &jsTlsClose, 1)
        && addNativeFunction(ctx, obj, "acceptFd", &jsAcceptFd, 3)
        && addNativeFunction(ctx, obj, "alpn", &jsTlsAlpn, 1)
        && addNativeFunction(ctx, obj, "peerAuthorized", &jsTlsPeerAuthorized, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "tls", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
