/*
 * Raw schannel (SSPI) HTTPS GET that reproduces the Last War launcher's
 * "error decoding response body ... operation timed out" under Wine.
 *
 * Wine before 11.6 (commit 35b1e7eb) reports the *full* TLS record size in
 * the second SECBUFFER_MISSING buffer of an incomplete DecryptMessage call
 * instead of the bytes still missing. The Rust schannel crate (used by the
 * launcher via reqwest/hyper-tls) reads exactly that many additional bytes
 * before retrying, so when a response ends inside a record that was split
 * across reads it waits for data that never comes.
 *
 * Every DecryptMessage result is traced; "MISSING WRONG" marks the bug.
 *
 * Usage: sspi_get.exe host path
 * Environment:
 *   RUSTMODE=1  emulate the schannel crate's read logic (stalls on buggy Wine)
 *   SCH5=1      use SCH_CREDENTIALS like the schannel crate (default SCHANNEL_CRED)
 *   TLS12=1     restrict to TLS 1.2
 */
#define SECURITY_WIN32
#define SCHANNEL_USE_BLACKLISTS
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <security.h>
#include <schannel.h>
#include <stdio.h>
#include <string.h>

#define RECV_TIMEOUT_MS 8000
#define BUF_SIZE (256 * 1024)

static LARGE_INTEGER freq, start;

static double now(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)(t.QuadPart - start.QuadPart) / freq.QuadPart;
}

static int recv_some(SOCKET s, char *buf, int cap)
{
    fd_set fds;
    struct timeval tv = { RECV_TIMEOUT_MS / 1000, 0 };
    FD_ZERO(&fds);
    FD_SET(s, &fds);
    if (select(0, &fds, NULL, NULL, &tv) <= 0) return -2; /* timeout */
    return recv(s, buf, cap, 0);
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 3) { fwprintf(stderr, L"usage: %s host path\n", argv[0]); return 2; }

    char host[256], path[1024];
    WideCharToMultiByte(CP_UTF8, 0, argv[1], -1, host, sizeof(host), NULL, NULL);
    WideCharToMultiByte(CP_UTF8, 0, argv[2], -1, path, sizeof(path), NULL, NULL);

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    struct addrinfo hints = { 0 }, *ai;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, "443", &hints, &ai)) { printf("dns failed\n"); return 1; }
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    if (connect(s, ai->ai_addr, (int)ai->ai_addrlen)) { printf("connect failed\n"); return 1; }

    SCHANNEL_CRED sc = { 0 };
    sc.dwVersion = SCHANNEL_CRED_VERSION;
    sc.dwFlags = SCH_CRED_NO_DEFAULT_CREDS | SCH_CRED_AUTO_CRED_VALIDATION;
    if (_wgetenv(L"TLS12")) sc.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
    CredHandle cred;
    TimeStamp ts;
    /* SCH_CREDENTIALS (what schannel-rs uses) is required for TLS 1.3. */
    TLS_PARAMETERS tp = { 0 };
    SCH_CREDENTIALS sc5 = { 0 };
    sc5.dwVersion = SCH_CREDENTIALS_VERSION;
    sc5.dwFlags = sc.dwFlags;
    sc5.cTlsParameters = 1;
    sc5.pTlsParameters = &tp;
    if (_wgetenv(L"TLS13")) tp.grbitDisabledProtocols = ~(DWORD)0x00002000;
    void *credp = _wgetenv(L"SCH5") || _wgetenv(L"TLS13") ? (void *)&sc5 : (void *)&sc;
    if (_wgetenv(L"TLS13")) sc.grbitEnabledProtocols = 0;
    SECURITY_STATUS st = AcquireCredentialsHandleA(NULL, UNISP_NAME_A, SECPKG_CRED_OUTBOUND,
                                                   NULL, credp, NULL, NULL, &cred, &ts);
    if (st != SEC_E_OK) { printf("AcquireCredentialsHandle 0x%lx\n", st); return 1; }

    DWORD req = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                ISC_REQ_EXTENDED_ERROR | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
    DWORD attrs;
    CtxtHandle ctx;
    static char in[BUF_SIZE];
    int in_len = 0;

    /* --- handshake --- */
    SecBuffer ob = { 0, SECBUFFER_TOKEN, NULL };
    SecBufferDesc obd = { SECBUFFER_VERSION, 1, &ob };
    st = InitializeSecurityContextA(&cred, NULL, host, req, 0, 0, NULL, 0, &ctx, &obd, &attrs, &ts);
    send(s, ob.pvBuffer, ob.cbBuffer, 0);
    FreeContextBuffer(ob.pvBuffer);

    while (st == SEC_I_CONTINUE_NEEDED || st == SEC_E_INCOMPLETE_MESSAGE) {
        if (in_len == 0 || st == SEC_E_INCOMPLETE_MESSAGE) {
            int n = recv_some(s, in + in_len, BUF_SIZE - in_len);
            if (n <= 0) { printf("handshake recv %d\n", n); return 1; }
            in_len += n;
        }
        SecBuffer ib[2] = { { in_len, SECBUFFER_TOKEN, in }, { 0, SECBUFFER_EMPTY, NULL } };
        SecBufferDesc ibd = { SECBUFFER_VERSION, 2, ib };
        SecBuffer ob2 = { 0, SECBUFFER_TOKEN, NULL };
        SecBufferDesc obd2 = { SECBUFFER_VERSION, 1, &ob2 };
        st = InitializeSecurityContextA(&cred, &ctx, host, req, 0, 0, &ibd, 0, NULL, &obd2, &attrs, &ts);
        if (st == SEC_E_INCOMPLETE_MESSAGE) continue;
        if (ob2.cbBuffer && ob2.pvBuffer) { send(s, ob2.pvBuffer, ob2.cbBuffer, 0); FreeContextBuffer(ob2.pvBuffer); }
        if (ib[1].BufferType == SECBUFFER_EXTRA) {
            memmove(in, in + in_len - ib[1].cbBuffer, ib[1].cbBuffer);
            in_len = ib[1].cbBuffer;
        } else {
            in_len = 0;
        }
    }
    if (st != SEC_E_OK) { printf("handshake failed 0x%lx\n", st); return 1; }

    SecPkgContext_ConnectionInfo ci;
    QueryContextAttributesA(&ctx, SECPKG_ATTR_CONNECTION_INFO, &ci);
    printf("[%.3f] handshake ok, protocol=0x%lx, leftover=%d bytes\n", now(), ci.dwProtocol, in_len);

    /* --- request --- */
    SecPkgContext_StreamSizes sz;
    QueryContextAttributesA(&ctx, SECPKG_ATTR_STREAM_SIZES, &sz);
    char reqtxt[2048];
    int rl = snprintf(reqtxt, sizeof(reqtxt),
                      "GET %s HTTP/1.1\r\naccept: */*\r\nhost: %s\r\n\r\n", path, host);
    static char out[64 * 1024];
    memcpy(out + sz.cbHeader, reqtxt, rl);
    SecBuffer eb[4] = { { sz.cbHeader, SECBUFFER_STREAM_HEADER, out },
                        { rl, SECBUFFER_DATA, out + sz.cbHeader },
                        { sz.cbTrailer, SECBUFFER_STREAM_TRAILER, out + sz.cbHeader + rl },
                        { 0, SECBUFFER_EMPTY, NULL } };
    SecBufferDesc ebd = { SECBUFFER_VERSION, 4, eb };
    EncryptMessage(&ctx, 0, &ebd, 0);
    send(s, out, eb[0].cbBuffer + eb[1].cbBuffer + eb[2].cbBuffer, 0);

    /* --- response --- */
    static char plain[BUF_SIZE];
    int plain_len = 0, body_start = -1;
    long content_length = -1;
    int round = 0;
    int rust = _wgetenv(L"RUSTMODE") != NULL, needs = 0;

    for (;;) {
        if (body_start >= 0 && content_length >= 0 && plain_len - body_start >= content_length) {
            printf("[%.3f] COMPLETE: body %d/%ld bytes\n", now(), plain_len - body_start, content_length);
            return 0;
        }

        st = SEC_E_INCOMPLETE_MESSAGE;
        if (in_len > 0) {
            SecBuffer db[4] = { { in_len, SECBUFFER_DATA, in }, { 0, SECBUFFER_EMPTY, NULL },
                                { 0, SECBUFFER_EMPTY, NULL }, { 0, SECBUFFER_EMPTY, NULL } };
            SecBufferDesc dbd = { SECBUFFER_VERSION, 4, db };
            st = DecryptMessage(&ctx, &dbd, 0, NULL);

            int data = 0, extra = 0, missing = -1;
            for (int i = 0; i < 4; i++) {
                if (db[i].BufferType == SECBUFFER_MISSING) missing = db[i].cbBuffer;
                if (db[i].BufferType == SECBUFFER_DATA) {
                    memcpy(plain + plain_len, db[i].pvBuffer, db[i].cbBuffer);
                    plain_len += db[i].cbBuffer;
                    data = db[i].cbBuffer;
                }
                if (db[i].BufferType == SECBUFFER_EXTRA) extra = db[i].cbBuffer;
            }
            /* TLS record length from the 5-byte header, to check SECBUFFER_MISSING. */
            int rec = in_len >= 5 ? 5 + ((unsigned char)in[3] << 8 | (unsigned char)in[4]) : -1;
            printf("[%.3f] #%d DecryptMessage(in=%d, record=%d) -> 0x%lx data=%d extra=%d missing=%d%s\n",
                   now(), ++round, in_len, rec, st, data, extra, missing,
                   (st == SEC_E_INCOMPLETE_MESSAGE && missing >= 0 && rec > 0 && missing != rec - in_len)
                       ? "  <-- MISSING WRONG" : "");

            if (st == SEC_E_OK || st == SEC_I_RENEGOTIATE || st == SEC_I_CONTEXT_EXPIRED) {
                if (extra) {
                    memmove(in, in + in_len - extra, extra);
                    in_len = extra;
                } else {
                    in_len = 0;
                }
            }
            if (st == SEC_I_CONTEXT_EXPIRED) { printf("[%.3f] server closed TLS\n", now()); return 1; }
            if (st != SEC_E_OK && st != SEC_E_INCOMPLETE_MESSAGE && st != SEC_I_RENEGOTIATE) {
                printf("[%.3f] decrypt error 0x%lx\n", now(), st);
                return 1;
            }
        }

        if (body_start < 0) {
            plain[plain_len] = 0;
            char *hdr_end = strstr(plain, "\r\n\r\n");
            if (hdr_end) {
                body_start = (int)(hdr_end - plain) + 4;
                char *cl = strstr(plain, "Content-Length:");
                if (!cl) cl = strstr(plain, "content-length:");
                if (cl) content_length = strtol(cl + 15, NULL, 10);
                printf("[%.3f] headers parsed, Content-Length=%ld\n", now(), content_length);
            }
        }

        if (body_start >= 0 && content_length >= 0 && plain_len - body_start >= content_length)
            continue; /* complete; reported at the top of the loop */

        if (rust && st == SEC_E_INCOMPLETE_MESSAGE && in_len > 0) {
            int m = -1;
            /* re-run to fetch the MISSING value (already traced above) */
            SecBuffer mb[4] = { { in_len, SECBUFFER_DATA, in }, { 0, SECBUFFER_EMPTY, NULL },
                                { 0, SECBUFFER_EMPTY, NULL }, { 0, SECBUFFER_EMPTY, NULL } };
            SecBufferDesc mbd = { SECBUFFER_VERSION, 4, mb };
            DecryptMessage(&ctx, &mbd, 0, NULL);
            for (int i = 0; i < 4; i++) if (mb[i].BufferType == SECBUFFER_MISSING) m = mb[i].cbBuffer;
            needs = m > 0 ? m : 1;
            while (needs > 0) {
                int n = recv_some(s, in + in_len, BUF_SIZE - in_len);
                if (n == -2) {
                    printf("[%.3f] STALL (schannel-rs logic): still waiting for %d bytes; %d bytes buffered "
                           "(enough for the record: %s)\n", now(), needs, in_len,
                           in_len >= 5 + ((unsigned char)in[3] << 8 | (unsigned char)in[4]) ? "YES" : "no");
                    return 3;
                }
                if (n <= 0) { printf("recv %d\n", n); return 1; }
                in_len += n;
                needs -= n;
                printf("[%.3f]    recv %d bytes (needs now %d)\n", now(), n, needs);
            }
            continue;
        }

        /* Need more ciphertext only when nothing decodable is buffered. */
        if (st == SEC_E_INCOMPLETE_MESSAGE || in_len == 0) {
            int n = recv_some(s, in + in_len, BUF_SIZE - in_len);
            if (n == -2) {
                printf("[%.3f] STALL: no socket data for %ds; body %d/%ld bytes, %d ciphertext bytes buffered\n",
                       now(), RECV_TIMEOUT_MS / 1000, body_start >= 0 ? plain_len - body_start : 0,
                       content_length, in_len);
                return 3;
            }
            if (n <= 0) { printf("[%.3f] recv %d\n", now(), n); return 1; }
            printf("[%.3f]    recv %d bytes\n", now(), n);
            in_len += n;
        }
    }
}
