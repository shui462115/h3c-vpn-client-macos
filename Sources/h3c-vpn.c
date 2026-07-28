#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

struct options {
    const char *gateway;
    const char *username;
    const char *core;
    const char *script;
    const char *servercert;
    int allow_tunnel_route;
    int dry_run;
    int route_check;
    int verbose;
};

static void secure_clear(void *buffer, size_t length) {
    volatile unsigned char *bytes = buffer;
    while (length-- > 0) *bytes++ = 0;
}

static void usage(FILE *out) {
    fprintf(out, "H3C VPN client for macOS (experimental)\n\n"
        "Usage: sudo h3c-vpn --gateway HOST:PORT --servercert PIN --username USER\n\n"
        "Required for connection: --gateway HOST:PORT --servercert pin-sha256:... --username USER\n"
        "Options: --core PATH --script PATH\n"
        "         --allow-tunnel-route --dry-run\n"
        "         --route-check --verbose --help\n");
}

static int parse_options(int argc, char **argv, struct options *o) {
    memset(o, 0, sizeof(*o));
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--help") || !strcmp(arg, "-h")) {
            usage(stdout);
            exit(0);
        } else if (!strcmp(arg, "--gateway")) {
            if (++i >= argc) return -1;
            o->gateway = argv[i];
        } else if (!strcmp(arg, "--username") || !strcmp(arg, "-u")) {
            if (++i >= argc) return -1;
            o->username = argv[i];
        } else if (!strcmp(arg, "--core")) {
            if (++i >= argc) return -1;
            o->core = argv[i];
        } else if (!strcmp(arg, "--script")) {
            if (++i >= argc) return -1;
            o->script = argv[i];
        } else if (!strcmp(arg, "--servercert")) {
            if (++i >= argc) return -1;
            o->servercert = argv[i];
        } else if (!strcmp(arg, "--allow-tunnel-route")) {
            o->allow_tunnel_route = 1;
        } else if (!strcmp(arg, "--dry-run")) {
            o->dry_run = 1;
        } else if (!strcmp(arg, "--route-check")) {
            o->route_check = 1;
        } else if (!strcmp(arg, "--verbose")) {
            o->verbose = 1;
        } else {
            fprintf(stderr, "Unknown option: %s\n", arg);
            return -1;
        }
    }
    return 0;
}

static void gateway_host(const char *gateway, char *host, size_t host_len) {
    const char *colon = strchr(gateway, ':');
    size_t len = colon ? (size_t)(colon - gateway) : strlen(gateway);
    if (len >= host_len) len = host_len - 1;
    memcpy(host, gateway, len);
    host[len] = '\0';
}

static int route_interface(const char *gateway, char *name, size_t name_len) {
    char host[256], line[512];
    gateway_host(gateway, host, sizeof(host));
    int fds[2];
    if (pipe(fds) != 0) return -1;
    pid_t child = fork();
    if (child < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    if (child == 0) {
        if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(126);
        close(fds[0]);
        close(fds[1]);
        execl("/sbin/route", "route", "-n", "get", host, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    FILE *pipe = fdopen(fds[0], "r");
    if (!pipe) {
        close(fds[0]);
        (void)waitpid(child, NULL, 0);
        return -1;
    }
    int found = 0;
    while (fgets(line, sizeof(line), pipe)) {
        char *label = line;
        while (*label == ' ' || *label == '\t') label++;
        if (!strncmp(label, "interface:", 10)) {
            char *value = label + 10;
            while (*value == ' ' || *value == '\t') value++;
            value[strcspn(value, "\r\n")] = '\0';
            snprintf(name, name_len, "%s", value);
            found = 1;
            break;
        }
    }
    fclose(pipe);
    int status = 0;
    if (waitpid(child, &status, 0) < 0) return -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return -1;
    return found ? 0 : -1;
}

static int resource_path(const char *explicit_path, const char *argv0,
                         const char *name, char *out, size_t out_len) {
    if (explicit_path) {
        snprintf(out, out_len, "%s", explicit_path);
        return access(out, X_OK) == 0 ? 0 : -1;
    }
    char executable[PATH_MAX];
    if (!realpath(argv0, executable)) return -1;
    char *slash = strrchr(executable, '/');
    if (!slash) return -1;
    *slash = '\0';
    snprintf(out, out_len, "%s/Resources/%s", executable, name);
    if (access(out, X_OK) == 0) return 0;
    snprintf(out, out_len, "%s/%s", executable, name);
    return access(out, X_OK) == 0 ? 0 : -1;
}

static void print_route(const char *gateway, const char *name) {
    printf("Route to %s: %s\n", gateway, name[0] ? name : "unknown");
    if (!strncmp(name, "utun", 4)) {
        printf("Warning: an existing utun tunnel may intercept the gateway.\n");
        printf("Disconnect Shadowrocket/other VPNs or configure a direct route.\n");
    }
}

static int read_password(char *password, size_t password_len) {
    FILE *tty = fopen("/dev/tty", "r+");
    if (!tty) tty = stdin;
    int fd = fileno(tty);
    struct termios original;
    int changed = 0;
    if (tcgetattr(fd, &original) == 0) {
        struct termios hidden = original;
        hidden.c_lflag &= (tcflag_t)~ECHO;
        if (tcsetattr(fd, TCSAFLUSH, &hidden) == 0) changed = 1;
    }
    fprintf(stderr, "Password (not saved): ");
    fflush(stderr);
    if (!fgets(password, (int)password_len, tty)) {
        if (changed) tcsetattr(fd, TCSAFLUSH, &original);
        if (tty != stdin) fclose(tty);
        return -1;
    }
    if (changed) tcsetattr(fd, TCSAFLUSH, &original);
    fprintf(stderr, "\n");
    password[strcspn(password, "\r\n")] = '\0';
    if (tty != stdin) fclose(tty);
    return 0;
}

static int write_all(int fd, const char *data, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, data, length);
        if (written <= 0) return -1;
        data += written;
        length -= (size_t)written;
    }
    return 0;
}

static int run_core(const char *core, const char *script, const char *gateway,
                    const char *username, const char *servercert,
                    char *password, int verbose) {
    int fds[2];
    if (pipe(fds) != 0) return 1;
    pid_t child = fork();
    if (child < 0) {
        close(fds[0]);
        close(fds[1]);
        return 1;
    }
    if (child == 0) {
        if (dup2(fds[0], STDIN_FILENO) < 0) _exit(126);
        close(fds[0]);
        close(fds[1]);
        char user_arg[1024], cert_arg[1024];
        snprintf(user_arg, sizeof(user_arg), "--user=%s", username);
        snprintf(cert_arg, sizeof(cert_arg), "--servercert=%s", servercert);
        char *args[14];
        int n = 0;
        args[n++] = (char *)core;
        args[n++] = "--protocol=h3c";
        args[n++] = "--passwd-on-stdin";
        args[n++] = user_arg;
        args[n++] = cert_arg;
        args[n++] = "--script";
        args[n++] = (char *)script;
        if (verbose) args[n++] = "--verbose";
        args[n++] = "--";
        args[n++] = (char *)gateway;
        args[n] = NULL;
        execv(core, args);
        _exit(127);
    }
    size_t length = strlen(password);
    int write_failed = write_all(fds[1], password, length) != 0 ||
                       write_all(fds[1], "\n", 1) != 0;
    secure_clear(password, length);
    close(fds[1]);
    int status = 0;
    if (waitpid(child, &status, 0) < 0) return 1;
    if (write_failed) return 1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

int main(int argc, char **argv) {
    struct options options;
    if (parse_options(argc, argv, &options) != 0) {
        usage(stderr);
        return 2;
    }
    if (!options.gateway) {
        fprintf(stderr, "Missing --gateway HOST[:PORT]\n");
        return 2;
    }
    char interface_name[64] = "unknown";
    if (route_interface(options.gateway, interface_name, sizeof(interface_name)) != 0)
        snprintf(interface_name, sizeof(interface_name), "unknown");
    print_route(options.gateway, interface_name);
    if (options.route_check) return 0;
    if (!options.allow_tunnel_route && !strncmp(interface_name, "utun", 4)) {
        fprintf(stderr, "Refusing connection: gateway route uses %s.\n", interface_name);
        fprintf(stderr, "Disconnect another VPN or pass --allow-tunnel-route.\n");
        return 3;
    }
    if (!options.username) {
        fprintf(stderr, "Missing --username USER\n");
        return 2;
    }
    const char *servercert = options.servercert;
    if (!servercert || strncmp(servercert, "pin-sha256:", 11) != 0 || strlen(servercert) <= 11) {
        fprintf(stderr, "Missing or invalid --servercert pin-sha256:...\n");
        return 2;
    }
    char core[PATH_MAX], script[PATH_MAX];
    if (resource_path(options.core, argv[0], "openconnect", core, sizeof(core)) != 0) {
        fprintf(stderr, "Cannot find openconnect core; use --core PATH.\n");
        return 2;
    }
    if (resource_path(options.script, argv[0], "vpnc-script", script, sizeof(script)) != 0) {
        fprintf(stderr, "Cannot find vpnc-script; use --script PATH.\n");
        return 2;
    }
    if (options.dry_run) {
        printf("Core: %s\nScript: %s\n", core, script);
        printf("Command: %s --protocol=h3c --passwd-on-stdin --user=%s --servercert=%s --script %s%s -- %s\n",
               core, options.username, servercert, script,
               options.verbose ? " --verbose" : "", options.gateway);
        printf("Password will not be read in dry-run.\n");
        return 0;
    }
    char password[4096];
    if (read_password(password, sizeof(password)) != 0) {
        fprintf(stderr, "Cannot read password from terminal.\n");
        return 2;
    }
    int status = run_core(core, script, options.gateway, options.username,
                          servercert, password, options.verbose);
    secure_clear(password, sizeof(password));
    return status;
}
