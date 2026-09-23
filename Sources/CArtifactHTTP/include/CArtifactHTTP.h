#ifndef SILICON_C_ARTIFACT_HTTP_H
#define SILICON_C_ARTIFACT_HTTP_H

#include <stdint.h>

typedef struct SiliconArtifactJob SiliconArtifactJob;

enum SiliconArtifactOutcome {
    SILICON_ARTIFACT_SUCCESS = 0,
    SILICON_ARTIFACT_REDIRECT = 1,
    SILICON_ARTIFACT_HTTP_STATUS = 2,
    SILICON_ARTIFACT_PRIVATE_ADDRESS = 3,
    SILICON_ARTIFACT_TOO_LARGE = 4,
    SILICON_ARTIFACT_CONTENT_TYPE = 5,
    SILICON_ARTIFACT_DISK = 6,
    SILICON_ARTIFACT_CANCELLED = 7,
    SILICON_ARTIFACT_NETWORK = 8,
    SILICON_ARTIFACT_EMPTY = 9,
    SILICON_ARTIFACT_AGGREGATE_LIMIT = 10
};

typedef int (*SiliconArtifactConsume)(void *context, int64_t byte_count);

// One HTTPS request only. Redirects are returned to Swift for policy validation.
// The caller owns the file descriptor. Production callers cannot override DNS.
SiliconArtifactJob *silicon_artifact_job_create(
    const char *url, int file_descriptor, int64_t maximum_bytes,
    int64_t timeout_milliseconds, int64_t disk_reserve_bytes,
    SiliconArtifactConsume consume, void *consume_context
);
enum SiliconArtifactOutcome silicon_artifact_job_perform(SiliconArtifactJob *job);
void silicon_artifact_job_cancel(SiliconArtifactJob *job);
long silicon_artifact_job_status(const SiliconArtifactJob *job);
int64_t silicon_artifact_job_bytes(const SiliconArtifactJob *job);
const char *silicon_artifact_job_location(const SiliconArtifactJob *job);
void silicon_artifact_job_destroy(SiliconArtifactJob *job);

// Transfer callbacks use this same raw-address classifier.
int silicon_artifact_public_ip(const char *address);

// DNS fixture hook for the tests. A trusted CA file additionally permits exactly 127.0.0.1
// for local HTTPS tests; NULL retains the production peer-address veto. Declared in every
// configuration because SwiftPM defines DEBUG for this C target but not for the Swift code
// importing it; only a DEBUG build of this file implements it, and any other build returns
// NULL, so a release binary carries no way to override DNS or trust.
SiliconArtifactJob *silicon_artifact_job_create_test(
    const char *url, int file_descriptor, int64_t maximum_bytes,
    int64_t timeout_milliseconds, int64_t disk_reserve_bytes,
    const char *resolve_override, const char *trusted_ca_file,
    SiliconArtifactConsume consume, void *consume_context
);

#endif
