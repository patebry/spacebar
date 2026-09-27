// A stand-in for an extension or writer process in test/updates: `proc <marker> <name> <delay ms>` waits for SIGTERM, then
// after the delay appends "<name> <realtime ns>" to the marker file and exits.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static const char *marker, *name;
static int delay;

static void term(int sig) {
    (void)sig;
    usleep(delay * 1000);
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    FILE *f = fopen(marker, "a");
    if (f) { fprintf(f, "%s %lld\n", name, (long long)t.tv_sec * 1000000000LL + t.tv_nsec); fclose(f); }
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    marker = argv[1];
    name = argv[2];
    delay = atoi(argv[3]);
    signal(SIGTERM, term);
    for (;;) pause();
}
