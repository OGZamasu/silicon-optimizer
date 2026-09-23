#include "CArtifactHTTP.h"

#include <arpa/inet.h>
#include <curl/curl.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <unistd.h>

struct SiliconArtifactJob {
    char *url;
#ifdef DEBUG
    char *resolve_override;
    char *trusted_ca_file;
    bool allow_fixture_loopback;
#endif
    int fd;
    int64_t maximum_bytes;
    int64_t timeout_ms;
    int64_t reserve_bytes;
    int64_t received;
    int64_t next_disk_check;
    long status;
    char location[4096];
    char content_type[256];
    int64_t content_length;
    SiliconArtifactConsume consume;
    void *consume_context;
    size_t header_bytes;
    atomic_bool cancelled;
    enum SiliconArtifactOutcome outcome;
};

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static void start_curl(void) { (void)curl_global_init(CURL_GLOBAL_DEFAULT); }

static bool public_ipv4(const unsigned char *b) {
    const unsigned a = b[0], second = b[1], third = b[2];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && second >= 64 && second <= 127) return false;
    if (a == 169 && second == 254) return false;
    if (a == 172 && second >= 16 && second <= 31) return false;
    if (a == 192 && second == 168) return false;
    if (a == 192 && second == 0 && third == 0) return false;
    if (a == 192 && second == 0 && third == 2) return false;
    if (a == 192 && second == 88 && third == 99) return false;
    if (a == 198 && (second == 18 || second == 19)) return false;
    if (a == 198 && second == 51 && third == 100) return false;
    if (a == 203 && second == 0 && third == 113) return false;
    return true;
}

static bool public_ipv6(const unsigned char *b) {
    // NAT64's well-known prefix, 64:ff9b::/96, is what DNS64 synthesizes on an IPv6-only
    // network for a host that has only IPv4. The translator forwards to the embedded
    // address, so that address is the destination the policy has to judge.
    static const unsigned char nat64[12] = { 0x00, 0x64, 0xff, 0x9b };
    if (!memcmp(b, nat64, sizeof(nat64))) return public_ipv4(b + 12);
    // Global unicast only; reject transition ranges that can embed a private IPv4 address.
    if ((b[0] & 0xe0) != 0x20) return false;
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] < 0x02) return false;
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false;
    if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4
    if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) return false;
    return true;
}

static bool public_sockaddr(const struct sockaddr *address, int family) {
    if (family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        return public_ipv4((const unsigned char *)&v4->sin_addr);
    }
    if (family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        return v6->sin6_scope_id == 0 && public_ipv6((const unsigned char *)&v6->sin6_addr);
    }
    return false;
}

#ifdef DEBUG
static bool fixture_loopback_sockaddr(const struct sockaddr *address, int family) {
    if (family != AF_INET) return false;
    const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
    const unsigned char *b = (const unsigned char *)&v4->sin_addr;
    return b[0] == 127 && b[1] == 0 && b[2] == 0 && b[3] == 1;
}
#endif

int silicon_artifact_public_ip(const char *address) {
    if (!address) return 0;
    struct in_addr v4;
    if (inet_pton(AF_INET, address, &v4) == 1)
        return public_ipv4((const unsigned char *)&v4);
    struct in6_addr v6;
    if (inet_pton(AF_INET6, address, &v6) == 1)
        return public_ipv6((const unsigned char *)&v6);
    return 0;
}

static curl_socket_t open_public_socket(void *opaque, curlsocktype purpose,
                                        struct curl_sockaddr *address) {
    SiliconArtifactJob *job = opaque;
    if (atomic_load(&job->cancelled)) {
        job->outcome = SILICON_ARTIFACT_CANCELLED;
        return CURL_SOCKET_BAD;
    }
    bool permitted = public_sockaddr(&address->addr, address->family);
#ifdef DEBUG
    if (job->allow_fixture_loopback &&
        fixture_loopback_sockaddr(&address->addr, address->family)) permitted = true;
#endif
    if (purpose != CURLSOCKTYPE_IPCXN || !permitted) {
        job->outcome = SILICON_ARTIFACT_PRIVATE_ADDRESS;
        return CURL_SOCKET_BAD;
    }
    if (job->outcome == SILICON_ARTIFACT_PRIVATE_ADDRESS)
        job->outcome = SILICON_ARTIFACT_NETWORK;
    return socket(address->family, address->socktype, address->protocol);
}

static int require_public_peer(void *opaque, char *remote_ip, char *local_ip,
                               int remote_port, int local_port) {
    (void)local_ip; (void)remote_port; (void)local_port;
    SiliconArtifactJob *job = opaque;
    if (atomic_load(&job->cancelled)) {
        job->outcome = SILICON_ARTIFACT_CANCELLED;
        return CURL_PREREQFUNC_ABORT;
    }
    bool permitted = silicon_artifact_public_ip(remote_ip);
#ifdef DEBUG
    if (job->allow_fixture_loopback && !strcmp(remote_ip, "127.0.0.1")) permitted = true;
#endif
    if (!permitted) {
        job->outcome = SILICON_ARTIFACT_PRIVATE_ADDRESS;
        return CURL_PREREQFUNC_ABORT;
    }
    if (job->outcome == SILICON_ARTIFACT_PRIVATE_ADDRESS)
        job->outcome = SILICON_ARTIFACT_NETWORK;
    return CURL_PREREQFUNC_OK;
}

static bool enough_disk(const SiliconArtifactJob *job, uint64_t required) {
    struct statfs disk;
    if (fstatfs(job->fd, &disk) != 0 || disk.f_bsize <= 0) return false;
    const __uint128_t available = (__uint128_t)disk.f_bavail * (uint64_t)disk.f_bsize;
    return available >= required;
}

static bool copy_header_value(char *to, size_t capacity, const char *start, size_t length) {
    while (length && (*start == ' ' || *start == '\t')) { start++; length--; }
    while (length && (start[length - 1] == '\r' || start[length - 1] == '\n' ||
                      start[length - 1] == ' ' || start[length - 1] == '\t')) length--;
    if (length >= capacity || memchr(start, '\0', length)) return false;
    memcpy(to, start, length);
    to[length] = '\0';
    return true;
}

static size_t receive_header(char *data, size_t size, size_t count, void *opaque) {
    SiliconArtifactJob *job = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > 65536 - job->header_bytes) { job->outcome = SILICON_ARTIFACT_NETWORK; return 0; }
    job->header_bytes += length;
    if (length >= 5 && !memcmp(data, "HTTP/", 5)) {
        job->status = 0;
        job->location[0] = '\0';
        job->content_type[0] = '\0';
        job->content_length = -1;
        char line[128];
        if (length >= sizeof(line)) return 0;
        memcpy(line, data, length);
        line[length] = '\0';
        char *space = strchr(line, ' ');
        if (!space) return 0;
        job->status = strtol(space + 1, NULL, 10);
        return job->status >= 100 && job->status <= 599 ? length : 0;
    }
    if (length == 2 && data[0] == '\r' && data[1] == '\n') {
        if (job->status >= 100 && job->status < 200) return length;
        if (job->status >= 300 && job->status < 400) {
            job->outcome = SILICON_ARTIFACT_REDIRECT;
            return 0; // Never read or charge a redirect body.
        }
        if (job->status < 200 || job->status >= 300) {
            job->outcome = SILICON_ARTIFACT_HTTP_STATUS;
            return 0;
        }
        if (job->content_length > job->maximum_bytes) {
            job->outcome = SILICON_ARTIFACT_TOO_LARGE;
            return 0;
        }
        if (job->content_type[0] && strncasecmp(job->content_type, "audio/", 6) &&
            strcasecmp(job->content_type, "application/octet-stream")) {
            job->outcome = SILICON_ARTIFACT_CONTENT_TYPE;
            return 0;
        }
        if (job->content_length > 0 && !enough_disk(
            job, (uint64_t)job->content_length + (uint64_t)job->reserve_bytes
        )) {
            job->outcome = SILICON_ARTIFACT_DISK;
            return 0;
        }
        return length;
    }
    if (length >= 9 && !strncasecmp(data, "Location:", 9)) {
        if (!copy_header_value(job->location, sizeof(job->location), data + 9, length - 9)) return 0;
    } else if (length >= 13 && !strncasecmp(data, "Content-Type:", 13)) {
        if (!copy_header_value(job->content_type, sizeof(job->content_type), data + 13, length - 13)) return 0;
        char *parameters = strchr(job->content_type, ';');
        if (parameters) *parameters = '\0';
        size_t type_length = strlen(job->content_type);
        while (type_length && isspace((unsigned char)job->content_type[type_length - 1]))
            job->content_type[--type_length] = '\0';
    } else if (length >= 15 && !strncasecmp(data, "Content-Length:", 15)) {
        char value[32];
        if (!copy_header_value(value, sizeof(value), data + 15, length - 15)) return 0;
        errno = 0;
        char *end = NULL;
        long long parsed = strtoll(value, &end, 10);
        if (errno || !end || *end || parsed < 0) return 0;
        job->content_length = parsed;
    }
    return length;
}

static size_t receive_body(char *data, size_t size, size_t count, void *opaque) {
    SiliconArtifactJob *job = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > (uint64_t)(job->maximum_bytes - job->received)) {
        job->outcome = SILICON_ARTIFACT_TOO_LARGE;
        return 0;
    }
    if (length && job->consume && !job->consume(job->consume_context, (int64_t)length)) {
        job->outcome = SILICON_ARTIFACT_AGGREGATE_LIMIT;
        return 0;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(job->fd, data + offset, length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { job->outcome = SILICON_ARTIFACT_DISK; return 0; }
        offset += (size_t)written;
    }
    job->received += (int64_t)length;
    if (job->received >= job->next_disk_check) {
        if (!enough_disk(job, (uint64_t)job->reserve_bytes)) {
            job->outcome = SILICON_ARTIFACT_DISK;
            return 0;
        }
        job->next_disk_check = job->received + 8 * 1024 * 1024;
    }
    return length;
}

static int check_cancel(void *opaque, curl_off_t expected_download, curl_off_t downloaded,
                        curl_off_t expected_upload, curl_off_t uploaded) {
    (void)expected_download; (void)downloaded; (void)expected_upload; (void)uploaded;
    SiliconArtifactJob *job = opaque;
    return atomic_load(&job->cancelled) ? 1 : 0;
}

SiliconArtifactJob *silicon_artifact_job_create(const char *url, int fd,
    int64_t maximum_bytes, int64_t timeout_ms, int64_t reserve_bytes,
    SiliconArtifactConsume consume, void *consume_context) {
    if (!url || fd < 0 || maximum_bytes <= 0 || timeout_ms <= 0 ||
        timeout_ms > LONG_MAX || reserve_bytes < 0) return NULL;
    SiliconArtifactJob *job = calloc(1, sizeof(*job));
    if (!job) return NULL;
    job->url = strdup(url);
    if (!job->url) {
        silicon_artifact_job_destroy(job);
        return NULL;
    }
    job->fd = fd;
    job->maximum_bytes = maximum_bytes;
    job->timeout_ms = timeout_ms;
    job->reserve_bytes = reserve_bytes;
    job->next_disk_check = 8 * 1024 * 1024;
    job->content_length = -1;
    job->consume = consume;
    job->consume_context = consume_context;
    job->outcome = SILICON_ARTIFACT_NETWORK;
    atomic_init(&job->cancelled, false);
    return job;
}

#ifdef DEBUG
SiliconArtifactJob *silicon_artifact_job_create_test(const char *url, int fd,
    int64_t maximum_bytes, int64_t timeout_ms, int64_t reserve_bytes,
    const char *resolve_override, const char *trusted_ca_file,
    SiliconArtifactConsume consume, void *consume_context) {
    if (resolve_override && strlen(resolve_override) > 4096) return NULL;
    SiliconArtifactJob *job = silicon_artifact_job_create(
        url, fd, maximum_bytes, timeout_ms, reserve_bytes, consume, consume_context
    );
    if (!job) return NULL;
    job->resolve_override = resolve_override ? strdup(resolve_override) : NULL;
    job->trusted_ca_file = trusted_ca_file ? strdup(trusted_ca_file) : NULL;
    if ((resolve_override && !job->resolve_override) ||
        (trusted_ca_file && !job->trusted_ca_file)) {
        silicon_artifact_job_destroy(job);
        return NULL;
    }
    job->allow_fixture_loopback = trusted_ca_file != NULL;
    return job;
}
#else
SiliconArtifactJob *silicon_artifact_job_create_test(const char *url, int fd,
    int64_t maximum_bytes, int64_t timeout_ms, int64_t reserve_bytes,
    const char *resolve_override, const char *trusted_ca_file,
    SiliconArtifactConsume consume, void *consume_context) {
    (void)url; (void)fd; (void)maximum_bytes; (void)timeout_ms; (void)reserve_bytes;
    (void)resolve_override; (void)trusted_ca_file; (void)consume; (void)consume_context;
    return NULL;
}
#endif

enum SiliconArtifactOutcome silicon_artifact_job_perform(SiliconArtifactJob *job) {
    if (!job) return SILICON_ARTIFACT_NETWORK;
    if (atomic_load(&job->cancelled)) return SILICON_ARTIFACT_CANCELLED;
    pthread_once(&curl_once, start_curl);
    CURL *curl = curl_easy_init();
    if (!curl) return SILICON_ARTIFACT_NETWORK;
    CURLcode code = CURLE_FAILED_INIT;
#ifdef DEBUG
    struct curl_slist *resolutions = NULL;
    if (job->resolve_override) {
        resolutions = curl_slist_append(NULL, job->resolve_override);
        if (!resolutions) goto done;
    }
#endif
#define SET(option, value) do { if (curl_easy_setopt(curl, option, value) != CURLE_OK) goto done; } while (0)
    SET(CURLOPT_URL, job->url);
    SET(CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_NETRC, CURL_NETRC_IGNORED);
    SET(CURLOPT_HTTPGET, 1L);
    SET(CURLOPT_ACCEPT_ENCODING, "identity");
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
#ifdef DEBUG
    if (job->trusted_ca_file) SET(CURLOPT_CAINFO, job->trusted_ca_file);
#endif
    SET(CURLOPT_FRESH_CONNECT, 1L);
    SET(CURLOPT_FORBID_REUSE, 1L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_TIMEOUT_MS, (long)job->timeout_ms);
    SET(CURLOPT_CONNECTTIMEOUT_MS, (long)(job->timeout_ms < 30000 ? job->timeout_ms : 30000));
    SET(CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)job->maximum_bytes);
    SET(CURLOPT_OPENSOCKETFUNCTION, open_public_socket);
    SET(CURLOPT_OPENSOCKETDATA, job);
    SET(CURLOPT_PREREQFUNCTION, require_public_peer);
    SET(CURLOPT_PREREQDATA, job);
    SET(CURLOPT_HEADERFUNCTION, receive_header);
    SET(CURLOPT_HEADERDATA, job);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, job);
    SET(CURLOPT_XFERINFOFUNCTION, check_cancel);
    SET(CURLOPT_XFERINFODATA, job);
    SET(CURLOPT_NOPROGRESS, 0L);
#ifdef DEBUG
    if (resolutions) SET(CURLOPT_RESOLVE, resolutions);
#endif
    if (atomic_load(&job->cancelled)) {
        job->outcome = SILICON_ARTIFACT_CANCELLED;
        goto done;
    }
    code = curl_easy_perform(curl);
    if (job->outcome == SILICON_ARTIFACT_PRIVATE_ADDRESS ||
        job->outcome == SILICON_ARTIFACT_TOO_LARGE ||
        job->outcome == SILICON_ARTIFACT_CONTENT_TYPE ||
        job->outcome == SILICON_ARTIFACT_DISK ||
        job->outcome == SILICON_ARTIFACT_AGGREGATE_LIMIT ||
        job->outcome == SILICON_ARTIFACT_HTTP_STATUS ||
        job->outcome == SILICON_ARTIFACT_REDIRECT) goto done;
    if (atomic_load(&job->cancelled)) job->outcome = SILICON_ARTIFACT_CANCELLED;
    else if (code == CURLE_FILESIZE_EXCEEDED) job->outcome = SILICON_ARTIFACT_TOO_LARGE;
    else if (code == CURLE_OK && job->status >= 200 && job->status < 300)
        job->outcome = job->received ? SILICON_ARTIFACT_SUCCESS : SILICON_ARTIFACT_EMPTY;
done:
#undef SET
#ifdef DEBUG
    if (resolutions) curl_slist_free_all(resolutions);
#endif
    curl_easy_cleanup(curl);
    return job->outcome;
}

void silicon_artifact_job_cancel(SiliconArtifactJob *job) {
    if (job) atomic_store(&job->cancelled, true);
}
long silicon_artifact_job_status(const SiliconArtifactJob *job) { return job ? job->status : 0; }
int64_t silicon_artifact_job_bytes(const SiliconArtifactJob *job) { return job ? job->received : 0; }
const char *silicon_artifact_job_location(const SiliconArtifactJob *job) {
    return job ? job->location : "";
}
void silicon_artifact_job_destroy(SiliconArtifactJob *job) {
    if (!job) return;
    free(job->url);
#ifdef DEBUG
    free(job->resolve_override);
    free(job->trusted_ca_file);
#endif
    free(job);
}
