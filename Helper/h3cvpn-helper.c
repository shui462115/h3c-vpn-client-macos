#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <net/if.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define SOCKET_PATH "/var/run/com.codex.h3cvpn.sock"
#define CORE_PATH "/Library/H3CVPN/Resources/openconnect"
#define SCRIPT_PATH "/Library/H3CVPN/Resources/vpnc-script"
#define OWNER_PATH "/Library/H3CVPN/owner.uid"
#define MAGIC 0x48334356u
#define VERSION 4u
#define CMD_START 1u
#define CMD_STOP 2u
#define CMD_STATUS 3u
#define MAX_GATEWAY 256u
#define MAX_USERNAME 256u
#define MAX_PASSWORD 4096u
#define MAX_PIN 256u
#define MAX_LOG 512u
#define MAX_INTERFACE IFNAMSIZ
#define STOP_TIMEOUT_MS 10000
#define STOP_POLL_INTERVAL_US 100000

static pid_t active_pid = 0;
static uid_t active_uid = (uid_t)-1;

static int read_all(int fd, void *buffer, size_t length) {
    unsigned char *p = buffer;
    while (length) {
        ssize_t n = read(fd, p, length);
        if (n <= 0) return -1;
        p += n;
        length -= (size_t)n;
    }
    return 0;
}

static int write_all(int fd, const void *buffer, size_t length) {
    const unsigned char *p = buffer;
    while (length) {
        ssize_t n = write(fd, p, length);
        if (n <= 0) return -1;
        p += n;
        length -= (size_t)n;
    }
    return 0;
}

static int send_response(int fd, int32_t status, pid_t pid, const char *message) {
    uint32_t header[3];
    size_t length = message ? strlen(message) : 0;
    if (length > 4096) length = 4096;
    header[0] = htonl((uint32_t)status);
    header[1] = htonl((uint32_t)pid);
    header[2] = htonl((uint32_t)length);
    if (write_all(fd, header, sizeof(header)) != 0) return -1;
    return length ? write_all(fd, message, length) : 0;
}

static int valid_token(const char *value, size_t length, size_t max_length) {
    if (!length || length > max_length) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)value[i];
        if (c == '\0' || c == '\n' || c == '\r' || c == '\t') return 0;
    }
    return 1;
}

static int valid_gateway(const char *gateway, size_t length) {
    if (!valid_token(gateway, length, MAX_GATEWAY)) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)gateway[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == ':' ||
              c == '-' || c == '[' || c == ']')) return 0;
    }
    return 1;
}

static int valid_pin(const char *pin, size_t length) {
    return valid_token(pin, length, MAX_PIN) &&
           length > 11 && !strncmp(pin, "pin-sha256:", 11);
}

static int valid_interface(const char *name, size_t length) {
    if (length == 0) return 1;
    if (length >= MAX_INTERFACE) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_')) return 0;
    }
    return if_nametoindex(name) != 0;
}

static int valid_log_for_uid(const char *path, size_t length, uid_t uid) {
    struct stat st;
    if (!valid_token(path, length, MAX_LOG) || strncmp(path, "/tmp/H3CVPN-", 12)) return 0;
    if (stat(path, &st) != 0 || st.st_uid != uid || !S_ISREG(st.st_mode)) return 0;
    return 1;
}

static int process_alive(pid_t pid) {
    if (pid <= 0) return 0;
    if (kill(pid, 0) == 0) return 1;
    return errno == EPERM;
}

static int authorized_uid(uid_t uid) {
    FILE *file = fopen(OWNER_PATH, "r");
    if (!file) return 0;
    unsigned long value = 0;
    int result = fscanf(file, "%lu", &value) == 1 && (uid_t)value == uid;
    fclose(file);
    return result;
}

static void reap_child(void) {
    if (active_pid > 0) {
        int status;
        pid_t result = waitpid(active_pid, &status, WNOHANG);
        if (result == active_pid || (result < 0 && errno == ECHILD)) {
            active_pid = 0;
            active_uid = (uid_t)-1;
        }
    }
}

static int wait_for_child_exit(pid_t pid) {
    int elapsed_ms = 0;
    for (;;) {
        int status;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return 1;
        if (result < 0 && errno != EINTR) return -1;
        if (elapsed_ms >= STOP_TIMEOUT_MS) return 0;
        usleep(STOP_POLL_INTERVAL_US);
        elapsed_ms += STOP_POLL_INTERVAL_US / 1000;
    }
}

static int start_vpn(uid_t uid, const char *gateway, const char *username,
                     const char *password, const char *pin, const char *log_path,
                     const char *local_interface, pid_t *pid_out) {
    reap_child();
    if (active_pid > 0 && process_alive(active_pid)) return -2;

    int password_pipe[2];
    if (pipe(password_pipe) != 0) return -1;
    pid_t child = fork();
    if (child < 0) {
        close(password_pipe[0]);
        close(password_pipe[1]);
        return -1;
    }
    if (child == 0) {
        int log_fd = open(log_path, O_WRONLY | O_APPEND);
        if (log_fd < 0) _exit(126);
        dup2(password_pipe[0], STDIN_FILENO);
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        close(log_fd);
        close(password_pipe[0]);
        close(password_pipe[1]);
        char user_arg[MAX_USERNAME + 8];
        char pin_arg[MAX_PIN + 16];
        snprintf(user_arg, sizeof(user_arg), "--user=%s", username);
        snprintf(pin_arg, sizeof(pin_arg), "--servercert=%s", pin);
        if (local_interface[0]) setenv("H3CVPN_BOUND_INTERFACE", local_interface, 1);
        execl(CORE_PATH, CORE_PATH, "--protocol=h3c", "--passwd-on-stdin",
              user_arg, pin_arg, "--script", SCRIPT_PATH, "--", gateway, (char *)NULL);
        _exit(127);
    }
    close(password_pipe[0]);
    size_t password_length = strlen(password);
    if (write_all(password_pipe[1], password, password_length) != 0 ||
        write_all(password_pipe[1], "\n", 1) != 0) {
        kill(child, SIGTERM);
    }
    memset((void *)password, 0, password_length);
    close(password_pipe[1]);
    active_pid = child;
    active_uid = uid;
    *pid_out = child;
    return 0;
}

static void handle_client(int client) {
    uid_t uid;
    gid_t gid;
    if (getpeereid(client, &uid, &gid) != 0) {
        send_response(client, -10, 0, "无法验证本地客户端身份");
        return;
    }
    if (!authorized_uid(uid)) {
        send_response(client, -20, 0, "当前用户未获授权使用后台服务");
        return;
    }
    uint32_t header[9];
    if (read_all(client, header, sizeof(header)) != 0 || ntohl(header[0]) != MAGIC ||
        ntohl(header[1]) != VERSION) {
        send_response(client, -11, 0, "请求格式错误");
        return;
    }
    uint32_t command = ntohl(header[2]);
    uint32_t lengths[6];
    for (int i = 0; i < 6; i++) lengths[i] = ntohl(header[3 + i]);
    if (lengths[0] > MAX_GATEWAY || lengths[1] > MAX_USERNAME ||
        lengths[2] > MAX_PASSWORD || lengths[3] > MAX_PIN || lengths[4] > MAX_LOG ||
        lengths[5] >= MAX_INTERFACE) {
        send_response(client, -12, 0, "请求字段过长");
        return;
    }
    char *gateway = calloc(1, lengths[0] + 1);
    char *username = calloc(1, lengths[1] + 1);
    char *password = calloc(1, lengths[2] + 1);
    char *pin = calloc(1, lengths[3] + 1);
    char *log_path = calloc(1, lengths[4] + 1);
    char *local_interface = calloc(1, lengths[5] + 1);
    if (!gateway || !username || !password || !pin || !log_path || !local_interface) {
        send_response(client, -13, 0, "内存不足");
        goto cleanup;
    }
    if (read_all(client, gateway, lengths[0]) || read_all(client, username, lengths[1]) ||
        read_all(client, password, lengths[2]) || read_all(client, pin, lengths[3]) ||
        read_all(client, log_path, lengths[4]) || read_all(client, local_interface, lengths[5])) {
        send_response(client, -14, 0, "请求读取失败");
        goto cleanup;
    }
    if (command == CMD_START) {
        if (!valid_gateway(gateway, lengths[0]) || !valid_token(username, lengths[1], MAX_USERNAME) ||
            !valid_token(password, lengths[2], MAX_PASSWORD) || !valid_pin(pin, lengths[3]) ||
            !valid_log_for_uid(log_path, lengths[4], uid) ||
            !valid_interface(local_interface, lengths[5])) {
            send_response(client, -15, 0, "连接参数不合法");
            goto cleanup;
        }
        pid_t pid = 0;
        int result = start_vpn(uid, gateway, username, password, pin, log_path,
                               local_interface, &pid);
        if (result == -2) {
            send_response(client, -2, active_pid, "已有连接进程");
        } else if (result != 0) {
            send_response(client, -16, 0, "无法启动 H3C 核心");
        } else {
            send_response(client, 0, pid, "连接进程已启动");
        }
    } else if (command == CMD_STOP) {
        pid_t requested = (pid_t)strtol(gateway, NULL, 10);
        if (uid != active_uid || requested != active_pid || requested <= 0) {
            send_response(client, -17, 0, "无权停止该连接");
        } else if (kill(requested, SIGTERM) != 0 && errno != ESRCH) {
            send_response(client, -18, requested, "停止连接失败");
        } else {
            int result = wait_for_child_exit(requested);
            if (result == 1) {
                active_pid = 0;
                active_uid = (uid_t)-1;
                send_response(client, 0, requested, "连接已断开");
            } else if (result == 0) {
                send_response(client, -21, requested, "连接仍在清理中，请稍后重试");
            } else {
                send_response(client, -22, requested, "无法确认连接进程已退出");
            }
        }
    } else if (command == CMD_STATUS) {
        reap_child();
        if (active_pid > 0 && uid == active_uid && process_alive(active_pid)) {
            send_response(client, 0, active_pid, "连接进程运行中");
        } else {
            send_response(client, 1, 0, "没有活动连接");
        }
    } else {
        send_response(client, -19, 0, "未知操作");
    }
cleanup:
    if (password) memset(password, 0, lengths[2]);
    free(gateway);
    free(username);
    free(password);
    free(pin);
    free(log_path);
    free(local_interface);
}

int main(void) {
    umask(0);
    signal(SIGPIPE, SIG_IGN);
    unlink(SOCKET_PATH);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || chmod(SOCKET_PATH, 0666) != 0 ||
        listen(server, 16) != 0) return 1;
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            sleep(1);
            continue;
        }
        handle_client(client);
        close(client);
    }
}
