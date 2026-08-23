/*
 * atlas-sensord — system-glibc HAL sensor bridge for the Atlas (WPE) browser.
 *
 * The Atlas engine (BrowserServer-atlas + WPEWebProcess) runs under a private, bundled glibc 2.25
 * and cannot dlopen the stock /usr/lib/libhal.so (built against the old system glibc). So this tiny
 * helper — built with the PalmPDK arm-none-linux-gnueabi gcc against the SYSTEM glibc — links libhal,
 * reads the accelerometer + gyroscope, and republishes the latest reading over a Unix socket that
 * BS-atlas connects to. BS then feeds the samples into WebKit's DeviceOrientation / DeviceMotion
 * events (see BrowserPageWPE sensor injection).
 *
 * Output line (newline-delimited, ASCII) pushed to every connected client at the sensor report rate:
 *     "S ax ay az gx gy gz\n"
 *   ax/ay/az = acceleration incl. gravity, in units of g   (HAL native)
 *   gx/gy/gz = angular velocity, in rad/s                   (HAL native)
 * A client that only wants orientation still gets the accel vector (BS derives beta/gamma from it).
 *
 * Build:  ./build-sensord.sh   (PalmPDK gcc, links libhal)
 * Run:    atlas-sensord [-v]    (-v also prints samples to stdout for debugging)
 * Socket: /tmp/atlas_sensord.sock  (SOCK_STREAM, abstract-free path; world-rw so BS as any uid can read)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <sys/wait.h>

#include <hal/hal_device.h>
#include <hal/hal_sensor_acceleration.h>
#include <hal/hal_sensor_angular_velocity.h>
#include <hal/hal_sensor_magnetic_field.h>
#include <hal/hal_sensor_linear_acceleration.h>

#define SOCK_PATH   "/tmp/atlas_sensord.sock"
#define MAX_CLIENTS 4

static int   g_verbose = 0;
static volatile sig_atomic_t g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

/* Open a HAL sensor of the given type: iterate to the first device id, then open it. */
static hal_device_handle_t open_sensor(hal_device_type_t type, const char *name)
{
    hal_device_iterator_handle_t it = NULL;
    hal_device_id_t id = NULL;
    hal_device_handle_t h = NULL;
    hal_error_t e;

    e = hal_get_device_iterator(type, HAL_FILTER_DEFAULT, &it);
    if (e != HAL_ERROR_SUCCESS || !it) { fprintf(stderr, "sensord: iterator(%s) err=%d\n", name, e); return NULL; }
    e = hal_device_iterator_get_next_id(it, &id);
    if (e != HAL_ERROR_SUCCESS || !id) { fprintf(stderr, "sensord: next_id(%s) err=%d\n", name, e); hal_release_device_iterator(it); return NULL; }
    e = hal_device_open(type, id, &h);
    hal_release_device_iterator(it);
    if (e != HAL_ERROR_SUCCESS || !h) { fprintf(stderr, "sensord: open(%s) err=%d\n", name, e); return NULL; }
    /* fastest reporting the device supports — DeviceMotion wants ~60Hz */
    hal_device_set_report_rate(h, HAL_REPORT_RATE_HIGHEST);
    if (g_verbose) fprintf(stderr, "sensord: opened %s (id=%s)\n", name, id);
    return h;
}

static int sensor_fd(hal_device_handle_t h)
{
    int fd = -1;
    if (h && hal_device_get_event_source(h, &fd) == HAL_ERROR_SUCCESS) return fd;
    return -1;
}

/* Drain all pending events on an acceleration handle, keeping the latest sample. */
static void drain_accel(hal_device_handle_t h, float *x, float *y, float *z)
{
    hal_event_handle_t ev = 0;
    hal_sensor_acceleration_event_item_t item;
    while (h && hal_device_get_event(h, &ev) == HAL_ERROR_SUCCESS && ev) {
        if (hal_sensor_acceleration_event_get_item(ev, &item) == HAL_ERROR_SUCCESS) {
            *x = item.x; *y = item.y; *z = item.z;
        }
        hal_device_release_event(h, ev);
        ev = 0;
    }
}

static void drain_gyro(hal_device_handle_t h, float *x, float *y, float *z)
{
    hal_event_handle_t ev = 0;
    hal_sensor_angular_velocity_event_item_t item;
    while (h && hal_device_get_event(h, &ev) == HAL_ERROR_SUCCESS && ev) {
        if (hal_sensor_angular_velocity_event_get_item(ev, &item) == HAL_ERROR_SUCCESS) {
            *x = item.x; *y = item.y; *z = item.z;
        }
        hal_device_release_event(h, ev);
        ev = 0;
    }
}

static void drain_mag(hal_device_handle_t h, float *x, float *y, float *z)   /* magnetometer, micro-Tesla (int) */
{
    hal_event_handle_t ev = 0;
    hal_sensor_magnetic_field_event_item_t item;
    while (h && hal_device_get_event(h, &ev) == HAL_ERROR_SUCCESS && ev) {
        if (hal_sensor_magnetic_field_event_get_item(ev, &item) == HAL_ERROR_SUCCESS) {
            *x = (float)item.x; *y = (float)item.y; *z = (float)item.z;
        }
        hal_device_release_event(h, ev);
        ev = 0;
    }
}

static void drain_lin(hal_device_handle_t h, float *x, float *y, float *z)   /* linear acceleration, m/s^2 (gravity removed) */
{
    hal_event_handle_t ev = 0;
    hal_sensor_linear_acceleration_event_item_t item;
    while (h && hal_device_get_event(h, &ev) == HAL_ERROR_SUCCESS && ev) {
        if (hal_sensor_linear_acceleration_event_get_item(ev, &item) == HAL_ERROR_SUCCESS) {
            *x = item.x; *y = item.y; *z = item.z;
        }
        hal_device_release_event(h, ev);
        ev = 0;
    }
}

/* Engine control. The Enyo app runs as luna inside LunaSysMgr and cannot exec, and anything routed
 * through BrowserServer is dead once BS wedges (atlas-wpe-env#3) — so a loopback HTTP GET here is how
 * it asks for a restart. We are the only root daemon in the package and we do not depend on BS.
 * Loopback-only; the one action it offers is restarting our own browser engine. */
#define CTL_PORT 8442

/* Detached so the poll loop keeps running. Never kills atlas-sensord — that is us.
 * Double-fork: `start atlas` blocks until the job is up, and we never wait(), so a single fork
 * would leave a zombie per restart. The grandchild is orphaned to init, which reaps it. */
static void restart_engine(void)
{
    pid_t p = fork();
    if (p < 0) return;
    if (p > 0) { waitpid(p, NULL, 0); return; }
    if (fork() != 0) _exit(0);
    setsid();
    system("/sbin/stop atlas >/dev/null 2>&1; "
           "/usr/bin/killall -9 BrowserServer-atlas qcamd qspkd qmicd >/dev/null 2>&1; "
           "/sbin/start atlas >/dev/null 2>&1");
    _exit(0);
}

/* Answer one control request. Returns 1 if a restart was asked for. */
static int ctl_serve(int c)
{
    struct timeval tv; tv.tv_sec = 0; tv.tv_usec = 300000;
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char req[256]; int n = recv(c, req, sizeof req - 1, 0);
    int ok = 0;
    if (n > 0) {
        req[n] = 0;
        ok = (strstr(req, "/restart-engine") != NULL);
        char rsp[192];
        snprintf(rsp, sizeof rsp,
                 "HTTP/1.0 %s\r\nAccess-Control-Allow-Origin: *\r\n"
                 "Content-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\n%s",
                 ok ? "200 OK" : "404 Not Found", ok ? "ok" : "no");
        send(c, rsp, strlen(rsp), 0);
    }
    close(c);
    return ok;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "-v") == 0) g_verbose = 1;
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig); signal(SIGPIPE, SIG_IGN);

    hal_device_handle_t hAccel = open_sensor(HAL_DEVICE_SENSOR_ACCELERATION, "acceleration");
    hal_device_handle_t hGyro  = open_sensor(HAL_DEVICE_SENSOR_ANGULAR_VELOCITY, "angular_velocity");
    hal_device_handle_t hMag   = open_sensor(HAL_DEVICE_SENSOR_MAGNETIC_FIELD, "magnetic_field");
    hal_device_handle_t hLin   = open_sensor(HAL_DEVICE_SENSOR_LINEAR_ACCELERATION, "linear_acceleration");
    if (!hAccel) { fprintf(stderr, "sensord: no accelerometer — fatal\n"); return 1; }
    int fdAccel = sensor_fd(hAccel);
    int fdGyro  = sensor_fd(hGyro);   /* all but accel are optional — a missing sensor just leaves its axes 0 */
    int fdMag   = sensor_fd(hMag);
    int fdLin   = sensor_fd(hLin);

    /* Unix listening socket */
    unlink(SOCK_PATH);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX; strncpy(sa.sun_path, SOCK_PATH, sizeof(sa.sun_path)-1);
    if (bind(srv, (struct sockaddr*)&sa, sizeof sa) < 0) { perror("sensord: bind"); return 1; }
    chmod(SOCK_PATH, 0666);
    listen(srv, MAX_CLIENTS);
    if (g_verbose) fprintf(stderr, "sensord: listening on %s (accelFd=%d gyroFd=%d)\n", SOCK_PATH, fdAccel, fdGyro);

    /* Control socket. Not fatal if it fails — the sensor bridge still works without it. */
    int ctl = socket(AF_INET, SOCK_STREAM, 0);
    if (ctl >= 0) {
        int one = 1;
        setsockopt(ctl, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in ca; memset(&ca, 0, sizeof ca);
        ca.sin_family = AF_INET;
        ca.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        ca.sin_port = htons(CTL_PORT);
        if (bind(ctl, (struct sockaddr*)&ca, sizeof ca) < 0 || listen(ctl, 4) < 0) {
            perror("sensord: ctl");
            close(ctl); ctl = -1;
        } else if (g_verbose) {
            fprintf(stderr, "sensord: engine control on 127.0.0.1:%d\n", CTL_PORT);
        }
    }

    int clients[MAX_CLIENTS]; int nclient = 0;
    float ax=0,ay=0,az=0, gx=0,gy=0,gz=0, mx=0,my=0,mz=0, lx=0,ly=0,lz=0;

    while (g_run) {
        struct pollfd pfd[6 + MAX_CLIENTS]; int n = 0;
        int iSrv = n; pfd[n].fd = srv; pfd[n].events = POLLIN; n++;
        int iCtl = -1;
        if (ctl >= 0) { iCtl = n; pfd[n].fd = ctl; pfd[n].events = POLLIN; n++; }
        int iAcc = -1, iGyr = -1, iMag = -1, iLin = -1;
        if (fdAccel >= 0) { iAcc = n; pfd[n].fd = fdAccel; pfd[n].events = POLLIN; n++; }
        if (fdGyro  >= 0) { iGyr = n; pfd[n].fd = fdGyro;  pfd[n].events = POLLIN; n++; }
        if (fdMag   >= 0) { iMag = n; pfd[n].fd = fdMag;   pfd[n].events = POLLIN; n++; }
        if (fdLin   >= 0) { iLin = n; pfd[n].fd = fdLin;   pfd[n].events = POLLIN; n++; }
        for (int i = 0; i < nclient; i++) { pfd[n].fd = clients[i]; pfd[n].events = 0; n++; }

        int r = poll(pfd, n, 1000);
        if (r < 0) { if (errno == EINTR) continue; break; }

        /* engine restart request */
        if (iCtl >= 0 && (pfd[iCtl].revents & POLLIN)) {
            int c = accept(ctl, NULL, NULL);
            if (c >= 0 && ctl_serve(c)) {
                fprintf(stderr, "sensord: engine restart requested\n");
                restart_engine();
            }
        }

        /* accept new clients */
        if (pfd[iSrv].revents & POLLIN) {
            int c = accept(srv, NULL, NULL);
            if (c >= 0) {
                /* Non-blocking: if a client (BS) stalls mid-rotation and its socket buffer fills, we DROP
                 * samples for it (EAGAIN) rather than block the whole daemon — which would freeze every
                 * client's stream. Sensor data is latest-wins, so dropping a few stale samples is fine. */
                fcntl(c, F_SETFL, O_NONBLOCK);
                if (nclient < MAX_CLIENTS) clients[nclient++] = c; else close(c);
            }
        }

        int updated = 0;
        if (iAcc >= 0 && (pfd[iAcc].revents & POLLIN)) { drain_accel(hAccel, &ax, &ay, &az); updated = 1; }
        if (iGyr >= 0 && (pfd[iGyr].revents & POLLIN)) { drain_gyro(hGyro, &gx, &gy, &gz); updated = 1; }
        if (iMag >= 0 && (pfd[iMag].revents & POLLIN)) { drain_mag(hMag, &mx, &my, &mz); updated = 1; }
        if (iLin >= 0 && (pfd[iLin].revents & POLLIN)) { drain_lin(hLin, &lx, &ly, &lz); updated = 1; }

        if (updated) {
            char line[256];
            /* S ax ay az gx gy gz mx my mz lx ly lz  (accel g, gyro rad/s, mag uT, linear m/s^2) */
            int len = snprintf(line, sizeof line,
                "S %.4f %.4f %.4f %.5f %.5f %.5f %.1f %.1f %.1f %.4f %.4f %.4f\n",
                ax, ay, az, gx, gy, gz, mx, my, mz, lx, ly, lz);
            if (g_verbose) fputs(line, stdout), fflush(stdout);
            for (int i = 0; i < nclient; ) {
                if (write(clients[i], line, len) < 0 && (errno == EPIPE || errno == ECONNRESET)) {
                    close(clients[i]); clients[i] = clients[--nclient];   /* drop dead client */
                } else i++;
            }
        }
    }

    for (int i = 0; i < nclient; i++) close(clients[i]);
    close(srv); unlink(SOCK_PATH);
    if (hAccel) hal_device_close(hAccel);
    if (hGyro)  hal_device_close(hGyro);
    if (hMag)   hal_device_close(hMag);
    if (hLin)   hal_device_close(hLin);
    return 0;
}
