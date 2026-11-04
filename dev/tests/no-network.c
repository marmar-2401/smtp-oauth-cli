#include <unistd.h>
int curl_easy_perform(void *handle) {
    (void)handle;
    const char marker[] = "NETWORK_STAGE_REACHED\n";
    (void)write(2, marker, sizeof(marker) - 1);
    return 6; /* CURLE_COULDNT_RESOLVE_HOST: prevent every real request. */
}
