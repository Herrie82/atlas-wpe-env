/* wm8994_i2c — read/write WM8994 codec registers over I2C on the TouchPad.
 * WM8994 uses 16-bit register addresses + 16-bit data, MSB first.
 * The internal mic is ANALOG (IN1LN + MICBIAS1) per the msm8x60.c machine driver;
 * MICBIAS1 (reg 0x01 bit 4, MICB1_ENA) has NO ALSA mixer control, so we set it here.
 *
 * usage:
 *   wm8994_i2c <bus> read  <reg>
 *   wm8994_i2c <bus> write <reg> <val>
 *   wm8994_i2c <bus> dump  <reg> <count>
 * reg/val are hex (0x..) or decimal.  bus = i2c bus number (WM8994 is on 4).
 * Build: atlas gcc125 (libc only).  Run under SYSTEM env.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#define WM8994_ADDR 0x1a

static int fd;

static int wm_read(uint16_t reg, uint16_t *val) {
    uint8_t rb[2] = { reg >> 8, reg & 0xff };
    uint8_t db[2];
    struct i2c_msg msgs[2] = {
        { .addr = WM8994_ADDR, .flags = 0,        .len = 2, .buf = rb },
        { .addr = WM8994_ADDR, .flags = I2C_M_RD, .len = 2, .buf = db },
    };
    struct i2c_rdwr_ioctl_data x = { .msgs = msgs, .nmsgs = 2 };
    if (ioctl(fd, I2C_RDWR, &x) < 0) return -1;
    *val = (db[0] << 8) | db[1];
    return 0;
}

static int wm_write(uint16_t reg, uint16_t val) {
    uint8_t b[4] = { reg >> 8, reg & 0xff, val >> 8, val & 0xff };
    if (write(fd, b, 4) != 4) return -1;
    return 0;
}

static unsigned parse(const char *s) { return (unsigned)strtoul(s, NULL, 0); }

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <bus> read|write|dump <reg> [val|count]\n", argv[0]); return 2; }
    char path[32]; snprintf(path, sizeof path, "/dev/i2c-%s", argv[1]);
    fd = open(path, O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
    /* I2C_SLAVE_FORCE: the kernel wm8994 driver is bound to 0x1a, so plain I2C_SLAVE
     * returns EBUSY. FORCE lets us share the bus (reads are safe; writes bypass the
     * driver's regmap cache but take effect on the hardware immediately). */
    if (ioctl(fd, I2C_SLAVE_FORCE, WM8994_ADDR) < 0) { fprintf(stderr, "I2C_SLAVE_FORCE 0x%x: %s\n", WM8994_ADDR, strerror(errno)); return 1; }

    if (!strcmp(argv[2], "read")) {
        uint16_t v; if (wm_read(parse(argv[3]), &v) < 0) { fprintf(stderr, "read fail: %s\n", strerror(errno)); return 1; }
        printf("R%#06x = %#06x\n", parse(argv[3]), v);
    } else if (!strcmp(argv[2], "write")) {
        if (argc < 5) { fprintf(stderr, "write needs val\n"); return 2; }
        if (wm_write(parse(argv[3]), parse(argv[4])) < 0) { fprintf(stderr, "write fail: %s\n", strerror(errno)); return 1; }
        uint16_t v; wm_read(parse(argv[3]), &v);
        printf("W%#06x <= %#06x  (readback %#06x)\n", parse(argv[3]), parse(argv[4]), v);
    } else if (!strcmp(argv[2], "dump")) {
        unsigned start = parse(argv[3]), n = argc >= 5 ? parse(argv[4]) : 1;
        for (unsigned i = 0; i < n; i++) {
            uint16_t v; if (wm_read(start + i, &v) == 0) printf("R%#06x = %#06x\n", start + i, v);
        }
    } else { fprintf(stderr, "unknown cmd %s\n", argv[2]); return 2; }
    return 0;
}
