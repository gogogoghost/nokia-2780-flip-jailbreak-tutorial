/*
 * kcap - Nokia 2780 (KaiOS 3.1) framebuffer recorder for the main display.
 *
 * Why this exists
 * ---------------
 * The 2780 shows nothing through the usual channels:
 *   - there is no DRM (/sys/class/drm absent) and no SurfaceFlinger;
 *   - /dev/graphics/fb0 is a vestigial mdss_fb: its memory is always zero and
 *     writing to it never reaches the panel;
 *   - the panel is an ST7789Vx2 qvga *command mode* SPI panel, so there is no
 *     scanout buffer anywhere in the file system.
 * The only place a full frame exists is inside the HWC HAL
 * (android.hardware.graphics.composer@2.1-service), which holds a ring of
 * 240x320 RGB565 ION dma-bufs (stride 512, 163840 bytes each).
 *
 * Those buffers are reachable, but not by reading:
 *   - their fds cannot be opened through /proc/<pid>/fd (anon_inode);
 *   - /proc/<pid>/map_files rejects them;
 *   - /proc/<pid>/mem returns EIO for the mappings because ion_vm_ops has no
 *     ->access vm_op, so remote-vm access fails.
 * So instead we borrow the HWC's own address space: ptrace stops one thread,
 * executes a handful of ordinary syscalls *in the target's context* with its
 * original registers restored and detached afterwards, and lets the target
 * itself copy the frames out. Nothing is patched, no code is injected and no
 * file outside /data is touched.
 *
 * Data path
 * ---------
 *   HWC thread  --write()-->  /data/local/tmp/kcap.fifo  --read()-->  kcap reader
 * and the reader keeps the buffer that changed, repacks it to a packed
 * 240x320 RGB565LE frame and appends it to the output file.
 *
 * usage:
 *   kcap rec <out.raw> <seconds> <fps> [composer-pid]
 *
 * Output is raw packed frames; encode with:
 *   ffmpeg -f rawvideo -pixel_format rgb565le -video_size 240x320 \
 *          -framerate 29 -i out.raw -pix_fmt yuv420p out.mp4
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <media/NdkMediaMuxer.h>

/* C linkage in both languages: the file is built as C++ so the NDK media
   headers compile, and bionic exports ptrace unmangled. */
#ifdef __cplusplus
extern "C"
#endif
long ptrace(int request, ...);
#define PTRACE_GETREGS  12
#define PTRACE_SETREGS  13
#define PTRACE_ATTACH   16
#define PTRACE_DETACH   17
#define PTRACE_SYSCALL  24
#define PTRACE_POKEDATA 5
#define PTRACE_CONT     7

#define __WALL 0x40000000

/* ARM EABI */
#define __NR_write  4
#define __NR_open   5
#define __NR_close  6
#define __NR_lseek  19
#define __NR_munmap 91
#define __NR_ioctl  54
#define __NR_mmap2  192
#define PROT_READ   1
#define MAP_SHARED  1
#define SEEK_END    2

#define DMA_BUF_IOCTL_SYNC 0x40086200UL
#define DMA_BUF_SYNC_READ  1
#define DMA_BUF_SYNC_START 0
#define DMA_BUF_SYNC_END   4

#define SCR_W 240
#define SCR_H 320
#define SCR_STRIDE 512
#define SCR_BPP 2
#define SCR_BUF_SIZE (SCR_STRIDE * SCR_H)   /* 163840 */
#define SCR_FRAME (SCR_W * SCR_H * SCR_BPP) /* 153600 */
#define MAX_BUFS 16

#define FIFO_PATH "/data/local/tmp/kcap.fifo"
#define FIFO_DIR "/data/local/tmp"

struct pt_regs { long uregs[18]; };
#define R0 0
#define R7 7
#define R15 15
#define CPSR 16

struct bufref {
    int fd;
    unsigned long size;
    unsigned long addr;
};

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int read_mem(pid_t pid, unsigned long addr, void *buf, size_t len)
{
    char p[64];
    snprintf(p, sizeof p, "/proc/%d/mem", (int)pid);
    int fd = open(p, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t got = pread(fd, buf, len, (off_t)addr);
    close(fd);
    return got == (ssize_t)len ? 0 : -1;
}

/* A real `svc #0` in the target, used as the syscall instruction we jump to. */
static unsigned long find_svc(pid_t pid)
{
    char p[64];
    snprintf(p, sizeof p, "/proc/%d/maps", (int)pid);
    FILE *f = fopen(p, "r");
    if (!f)
        return 0;

    char line[512];
    unsigned long found = 0;
    uint8_t *buf = (uint8_t *)malloc(64 * 1024);
    if (!buf) {
        fclose(f);
        return 0;
    }
    while (!found && fgets(line, sizeof line, f)) {
        unsigned long s, e, off;
        char perms[8], dev[16], name[256];
        long ino;
        name[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %lx %15s %ld %255[^\n]", &s, &e, perms, &off, dev,
                   &ino, name) < 4)
            continue;
        if (perms[0] != 'r' || perms[2] != 'x')
            continue;
        for (unsigned long a = s; a < e && !found; a += 64 * 1024) {
            size_t len = (size_t)(e - a);
            if (len > 64 * 1024)
                len = 64 * 1024;
            if (read_mem(pid, a, buf, len))
                break;
            for (size_t i = 0; i + 4 <= len; i += 4) {
                uint32_t w;
                memcpy(&w, buf + i, 4);
                if (w == 0xEF000000u) {
                    found = a + i;
                    break;
                }
            }
        }
    }
    free(buf);
    fclose(f);
    return found;
}

static int wait_stop(pid_t pid, int *sig)
{
    int status;
    if (waitpid(pid, &status, __WALL) < 0)
        return -1;
    if (WIFSTOPPED(status)) {
        if (sig)
            *sig = WSTOPSIG(status);
        return 0;
    }
    return -1;
}

static pid_t g_pid;
static unsigned long g_svc;
static struct pt_regs g_saved;

/* Run one syscall inside the target and return its result. */
static long target_syscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5,
                           int *ok)
{
    struct pt_regs r = g_saved;
    r.uregs[0] = a0; r.uregs[1] = a1; r.uregs[2] = a2;
    r.uregs[3] = a3; r.uregs[4] = a4; r.uregs[5] = a5;
    r.uregs[R7] = nr;
    r.uregs[R15] = (long)g_svc;
    /* The svc we jump to is an ARM instruction: clear the Thumb bit (CPSR.T)
       so it is not decoded as Thumb halfwords. */
    r.uregs[CPSR] = g_saved.uregs[CPSR] & ~0x20;

    *ok = 0;
    if (ptrace(PTRACE_SETREGS, g_pid, 0, &r) < 0)
        return -1;
    if (ptrace(PTRACE_SYSCALL, g_pid, 0, 0) < 0)
        return -1;
    int sig = 0;
    if (wait_stop(g_pid, &sig))
        return -1;
    if (ptrace(PTRACE_SYSCALL, g_pid, 0, 0) < 0)
        return -1;
    if (wait_stop(g_pid, &sig))
        return -1;

    struct pt_regs out;
    if (ptrace(PTRACE_GETREGS, g_pid, 0, &out) < 0)
        return -1;
    *ok = 1;
    return out.uregs[0];
}

static int pokew(unsigned long addr, unsigned long val)
{
    return ptrace(PTRACE_POKEDATA, g_pid, addr, (void *)val) == -1 ? -1 : 0;
}

static void poke64(unsigned long addr, unsigned long long v)
{
    pokew(addr, (unsigned long)v);
    pokew(addr + 4, (unsigned long)(v >> 32));
}

static int attach_target(pid_t pid)
{
    g_pid = pid;
    if (!g_svc) {
        g_svc = find_svc(pid);
        if (!g_svc)
            return -1;
    }
    if (ptrace(PTRACE_ATTACH, g_pid, 0, 0) < 0)
        return -1;
    int sig;
    if (wait_stop(g_pid, &sig))
        return -1;
    if (ptrace(PTRACE_GETREGS, g_pid, 0, &g_saved) < 0)
        return -1;
    return 0;
}

static void detach_target(void)
{
    ptrace(PTRACE_SETREGS, g_pid, 0, &g_saved);
    ptrace(PTRACE_DETACH, g_pid, 0, 0);
}

static pid_t find_composer(void)
{
    DIR *d = opendir("/proc");
    if (!d)
        return -1;
    struct dirent *e;
    pid_t found = -1;
    while ((e = readdir(d)) && found < 0) {
        long pid = atol(e->d_name);
        if (pid <= 0)
            continue;
        char p[128], cmd[256];
        snprintf(p, sizeof p, "/proc/%ld/cmdline", pid);
        int fd = open(p, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        int n = read(fd, cmd, sizeof cmd - 1);
        close(fd);
        if (n <= 0)
            continue;
        cmd[n] = 0;
        if (strstr(cmd, "graphics.composer"))
            found = (pid_t)pid;
    }
    closedir(d);
    return found;
}

/* ------------------------------------------------------------------ */
/* on-device H.264 encoding (libmediandk)                             */
/*                                                                    */
/* The encoder is the Venus video processor, reached through the      */
/* platform OMX component -- not the GPU: the Adreno in this SoC has  */
/* no video encode block. The GPU could only help with the RGB565 to  */
/* NV12 conversion, which is far cheaper on the CPU at 240x320.       */
/* ------------------------------------------------------------------ */

#define ENC_BITRATE_DEFAULT 1500000

static long g_frames_written;

static int g_mp4;
static int g_bitrate = ENC_BITRATE_DEFAULT;
static double g_fps = 29.0;
static AMediaCodec *g_codec;
static AMediaMuxer *g_muxer;
static int g_track = -1;
static int g_muxer_started;

static int enc_open(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) {
        perror(path);
        return -1;
    }
    g_muxer = AMediaMuxer_new(fd, AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4);
    if (!g_muxer) {
        fprintf(stderr, "kcap: cannot create an MP4 muxer\n");
        close(fd);
        return -1;
    }

    g_codec = AMediaCodec_createEncoderByType("video/avc");
    if (!g_codec) {
        fprintf(stderr, "kcap: no H.264 encoder is available\n");
        return -1;
    }
    char *nm = NULL;
    AMediaCodec_getName(g_codec, &nm);

    AMediaFormat *fmt = AMediaFormat_new();
    AMediaFormat_setString(fmt, AMEDIAFORMAT_KEY_MIME, "video/avc");
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_WIDTH, SCR_W);
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_HEIGHT, SCR_H);
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_BIT_RATE, g_bitrate);
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_FRAME_RATE, (int)(g_fps + 0.5));
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
    AMediaFormat_setInt32(fmt, AMEDIAFORMAT_KEY_COLOR_FORMAT, 21 /* NV12 */);

    media_status_t st =
        AMediaCodec_configure(g_codec, fmt, NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
    AMediaFormat_delete(fmt);
    if (st != AMEDIA_OK) {
        fprintf(stderr, "kcap: encoder configure failed (%d)\n", st);
        return -1;
    }
    if ((st = AMediaCodec_start(g_codec)) != AMEDIA_OK) {
        fprintf(stderr, "kcap: encoder start failed (%d)\n", st);
        return -1;
    }
    fprintf(stderr, "kcap: encoding %dx%d @ %.0f fps at %d bit/s with %s\n", SCR_W, SCR_H,
            g_fps, g_bitrate, nm ? nm : "H.264");
    free(nm);
    return 0;
}

/* RGB565 (stride 512) to NV12 (stride 240), BT.601 limited range. The result
   goes straight into the codec's input buffer, so there is no extra copy. */
static void rgb565_to_nv12(const uint8_t *src, uint8_t *dst, size_t cap)
{
    uint8_t *uv = dst + (size_t)SCR_W * SCR_H;
    memset(dst, 0, cap);
    for (int y = 0; y < SCR_H; y += 2) {
        const uint16_t *r0 = (const uint16_t *)(src + (size_t)y * SCR_STRIDE);
        const uint16_t *r1 = (const uint16_t *)(src + (size_t)(y + 1) * SCR_STRIDE);
        uint8_t *y0 = dst + (size_t)y * SCR_W;
        uint8_t *y1 = y0 + SCR_W;
        uint8_t *uvrow = uv + (size_t)(y / 2) * SCR_W;
        for (int x = 0; x < SCR_W; x += 2) {
            int sr = 0, sg = 0, sb = 0;
            for (int k = 0; k < 4; k++) {
                uint16_t p = (k < 2) ? r0[x + (k & 1)] : r1[x + (k & 1)];
                int r = (p >> 11) & 0x1f, g = (p >> 5) & 0x3f, b = p & 0x1f;
                r = (r << 3) | (r >> 2);
                g = (g << 2) | (g >> 4);
                b = (b << 3) | (b >> 2);
                sr += r; sg += g; sb += b;
                int yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                if (k < 2)
                    y0[x + k] = (uint8_t)yy;
                else
                    y1[x + (k & 1)] = (uint8_t)yy;
            }
            sr >>= 2; sg >>= 2; sb >>= 2;
            int u = ((-38 * sr - 74 * sg + 112 * sb + 128) >> 8) + 128;
            int v = ((112 * sr - 94 * sg - 18 * sb + 128) >> 8) + 128;
            uvrow[x] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
            uvrow[x + 1] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
    }
}

static void enc_drain(int timeout_us, int *eos)
{
    for (;;) {
        AMediaCodecBufferInfo info;
        ssize_t ob = AMediaCodec_dequeueOutputBuffer(g_codec, &info, timeout_us);
        timeout_us = 0;
        if (ob == AMEDIACODEC_INFO_TRY_AGAIN_LATER ||
            ob == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
            return;
        if (ob == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat *of = AMediaCodec_getOutputFormat(g_codec);
            if (!g_muxer_started) {
                g_track = (int)AMediaMuxer_addTrack(g_muxer, of);
                if (AMediaMuxer_start(g_muxer) != AMEDIA_OK)
                    fprintf(stderr, "kcap: muxer start failed\n");
                g_muxer_started = 1;
            }
            AMediaFormat_delete(of);
            continue;
        }
        if (ob < 0)
            return;
        size_t osz = 0;
        uint8_t *obuf = AMediaCodec_getOutputBuffer(g_codec, (size_t)ob, &osz);
        if (info.size > 0 && g_muxer_started && g_track >= 0 && obuf)
            AMediaMuxer_writeSampleData(g_muxer, g_track, obuf, &info);
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
            *eos = 1;
        AMediaCodec_releaseOutputBuffer(g_codec, (size_t)ob, false);
        if (*eos)
            return;
    }
}

static void enc_feed(const uint8_t *src)
{
    int64_t pts = (int64_t)(g_frames_written * 1000000.0 / g_fps);
    ssize_t ib = AMediaCodec_dequeueInputBuffer(g_codec, 100000);
    if (ib >= 0) {
        size_t cap = 0;
        uint8_t *p = AMediaCodec_getInputBuffer(g_codec, (size_t)ib, &cap);
        if (p) {
            rgb565_to_nv12(src, p, cap);
            AMediaCodec_queueInputBuffer(g_codec, (size_t)ib, 0,
                                         (size_t)SCR_W * SCR_H * 3 / 2, pts, 0);
        }
    }
    int eos = 0;
    enc_drain(0, &eos);
}

static void enc_close(void)
{
    if (!g_codec)
        return;
    ssize_t ib = AMediaCodec_dequeueInputBuffer(g_codec, 200000);
    if (ib >= 0)
        AMediaCodec_queueInputBuffer(g_codec, (size_t)ib, 0, 0, 0,
                                     AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
    int eos = 0;
    for (int i = 0; i < 400 && !eos; i++)
        enc_drain(50000, &eos);
    AMediaCodec_stop(g_codec);
    AMediaCodec_delete(g_codec);
    g_codec = NULL;
    if (g_muxer) {
        if (g_muxer_started)
            AMediaMuxer_stop(g_muxer);
        AMediaMuxer_delete(g_muxer);
        g_muxer = NULL;
    }
}

/* ------------------------------------------------------------------ */
/* reader side: drain the fifo, keep the buffer that changed          */
/* ------------------------------------------------------------------ */

static int g_fifo_rd = -1;
static int g_nbufs;
static unsigned long g_bufsize;
static int g_out_fd = -1;
static volatile int g_stop;
static uint8_t *g_prev[MAX_BUFS];
static uint8_t *g_cur[MAX_BUFS];
static uint8_t g_pack[SCR_FRAME];

static ssize_t read_full(int fd, uint8_t *dst, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, dst + done, len - done);
        if (n > 0) {
            done += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) {
            if (g_stop)
                return -1;
            usleep(100);
            continue;
        }
        return -1;
    }
    return (ssize_t)done;
}

static void *reader_main(void *arg)
{
    (void)arg;
    int have_prev = 0;
    int last_pick = 0;
    while (!g_stop) {
        for (int i = 0; i < g_nbufs; i++) {
            if (read_full(g_fifo_rd, g_cur[i], g_bufsize) < 0)
                return NULL;
        }
        int pick = -1;
        for (int i = 0; i < g_nbufs; i++) {
            if (!have_prev || memcmp(g_prev[i], g_cur[i], g_bufsize) != 0)
                pick = i;
        }
        if (pick < 0)
            pick = last_pick;
        last_pick = pick;
        have_prev = 1;
        for (int i = 0; i < g_nbufs; i++)
            memcpy(g_prev[i], g_cur[i], g_bufsize);

        const uint8_t *src = g_cur[pick];
        if (g_mp4) {
            enc_feed(src);
        } else {
            for (int y = 0; y < SCR_H; y++)
                memcpy(g_pack + (size_t)y * SCR_W * SCR_BPP,
                       src + (size_t)y * SCR_STRIDE, SCR_W * SCR_BPP);
            if (write(g_out_fd, g_pack, SCR_FRAME) != SCR_FRAME)
                return NULL;
        }
        g_frames_written++;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */

static int composer_open_fifo(unsigned long scratch)
{
    /* the path has to live in the target's memory, so poke it into our
       scratch page and let the target run open() on its own address space */
    unsigned char pathbuf[256];
    size_t plen = strlen(FIFO_PATH) + 1;
    memset(pathbuf, 0, sizeof pathbuf);
    memcpy(pathbuf, FIFO_PATH, plen - 1);
    for (size_t i = 0; i < plen; i += 4) {
        unsigned long w = 0;
        for (int k = 0; k < 4; k++)
            if (i + k < plen)
                w |= (unsigned long)pathbuf[i + k] << (8 * k);
        if (pokew(scratch + i, w))
            return -1;
    }
    int ok;
    long fd = target_syscall(__NR_open, scratch, 1 /*O_WRONLY*/, 0, 0, 0, 0, &ok);
    if (!ok || fd < 0)
        return -1;
    return (int)fd;
}

static unsigned long make_scratch(void)
{
    int ok;
    long a = target_syscall(__NR_mmap2, 0, 4096, PROT_READ | 2, 0x02 | 0x20, -1, 0, &ok);
    unsigned long ua = (unsigned long)a;
    if (!ok || ua >= (unsigned long)-4095)
        return 0;
    return ua;
}

/* attach, map the display buffers, hand the target a fifo to write into */
static int setup(struct bufref *bufs, int *nb, int *fifo_wr, unsigned long *scratch_out,
                 unsigned long want)
{
    pid_t pid = find_composer();
    if (pid <= 0) {
        fprintf(stderr, "kcap: composer HAL not found\n");
        return -1;
    }
    if (attach_target(pid) < 0) {
        fprintf(stderr, "kcap: cannot attach to %d (%s)\n", (int)pid, strerror(errno));
        return -1;
    }
    unsigned long scratch = make_scratch();
    if (!scratch) {
        fprintf(stderr, "kcap: no scratch page in target\n");
        detach_target();
        return -1;
    }

    char dirp[64];
    snprintf(dirp, sizeof dirp, "/proc/%d/fd", (int)pid);
    DIR *d = opendir(dirp);
    int n = 0, ok;
    if (d) {
        struct dirent *e;
        char link[128], tgt[128];
        while ((e = readdir(d)) && n < MAX_BUFS) {
            int fd = atoi(e->d_name);
            if (fd <= 0)
                continue;
            snprintf(link, sizeof link, "/proc/%d/fd/%d", (int)pid, fd);
            ssize_t rn = readlink(link, tgt, sizeof tgt - 1);
            if (rn <= 0)
                continue;
            tgt[rn] = 0;
            if (!strstr(tgt, "dmabuf"))
                continue;
            long sz = target_syscall(__NR_lseek, fd, 0, SEEK_END, 0, 0, 0, &ok);
            if (!ok || sz <= 0 || (unsigned long)sz != want)
                continue;
            long a = target_syscall(__NR_mmap2, 0, sz, PROT_READ, MAP_SHARED, fd, 0, &ok);
            unsigned long ua = (unsigned long)a;
            if (!ok || ua >= (unsigned long)-4095)
                continue;
            bufs[n].fd = fd;
            bufs[n].size = (unsigned long)sz;
            bufs[n].addr = ua;
            n++;
        }
        closedir(d);
    }
    if (!n) {
        fprintf(stderr, "kcap: no %lu-byte dma-bufs in composer pid %d\n", want, (int)pid);
        detach_target();
        return -1;
    }
    int fw = composer_open_fifo(scratch);
    /* The GPU writes these buffers, so a CPU read needs the exporter's cache
       maintenance first: ioctl(fd, DMA_BUF_IOCTL_SYNC, {START,READ}). The two
       flag words live in the scratch page and never change. */
    poke64(scratch + 8, (unsigned long long)(DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ));
    poke64(scratch + 16, (unsigned long long)(DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ));
    detach_target();
    if (fw < 0) {
        fprintf(stderr, "kcap: composer could not open %s\n", FIFO_PATH);
        return -1;
    }
    *nb = n;
    *fifo_wr = fw;
    *scratch_out = scratch;
    fprintf(stderr, "kcap: composer pid %d, %d display buffer(s), fifo fd %d\n", (int)pid, n, fw);
    return 0;
}

/* one frame: sync + write every display buffer down the fifo */
static int grab(const struct bufref *bufs, int nb, int fifo_wr, unsigned long scratch)
{
    if (attach_target(g_pid) < 0)
        return -1;
    int ok, rc = 0;
    for (int i = 0; i < nb; i++) {
        target_syscall(__NR_ioctl, bufs[i].fd, DMA_BUF_IOCTL_SYNC, scratch + 8, 0, 0, 0, &ok);
        long w = target_syscall(__NR_write, fifo_wr, bufs[i].addr, bufs[i].size, 0, 0, 0, &ok);
        if (!ok || w != (long)bufs[i].size)
            rc = -1;
    }
    detach_target();
    return rc;
}

/* hand the HAL back exactly what we borrowed: close the fifo and drop the
   mappings we added, so repeated runs do not leak fds or address space */
static void teardown(const struct bufref *bufs, int nb, int fifo_wr)
{
    if (attach_target(g_pid) < 0)
        return;
    int ok;
    if (fifo_wr >= 0)
        target_syscall(__NR_close, fifo_wr, 0, 0, 0, 0, 0, &ok);
    for (int i = 0; i < nb; i++)
        target_syscall(__NR_munmap, bufs[i].addr, bufs[i].size, 0, 0, 0, 0, &ok);
    detach_target();
}

/* The FIFO lives in /data/local/tmp and is owned by this binary from start to
   finish: it is created here and removed again on every exit path, so nothing
   has to be cleaned up over adb. */
static int g_fifo_made;

static void fifo_remove(void)
{
    if (g_fifo_made) {
        g_fifo_made = 0;
        unlink(FIFO_PATH);
    }
}

/* A stop request only asks the main loop to finish normally, so the encoder can
   flush and the MP4 still gets its moov atom. Asking a second time gives up on
   that clean exit. <out>.stop is the out-of-band way to ask, for when the
   recorder was started detached and has no terminal to press Ctrl-C in. */
static volatile sig_atomic_t g_stop_req;
static char g_stop_path[512];

static void on_stop_signal(int sig)
{
    if (g_stop_req) {
        fifo_remove();
        _exit(128 + sig);
    }
    g_stop_req = 1;
}

static int stop_requested(void)
{
    if (g_stop_req)
        return 1;
    return g_stop_path[0] && access(g_stop_path, F_OK) == 0;
}

/* --------------------------------------------------------------- */
/* progress reporting                                              */
/*                                                                 */
/* Two channels, because the recorder is usefully run either way:  */
/* a line on stderr for a terminal (or the log of a detached run), */
/* and a tiny <out>.progress file holding the same numbers so a    */
/* host script can poll the elapsed time without parsing the log.  */
/* --------------------------------------------------------------- */

static int g_progress_ivl; /* seconds between reports; 0 = off */
static char g_progress_path[512];
static double g_t_start;
static double g_t_next_report;

static void report_progress(void)
{
    double t = now_seconds();
    if (t < g_t_next_report)
        return;
    g_t_next_report = t + g_progress_ivl;

    double el = t - g_t_start;
    double rate = el > 0 ? (double)g_frames_written / el : 0;
    fprintf(stderr, "kcap: %.1fs elapsed, %ld frames (%.1f fps)\n", el, g_frames_written,
            rate);

    if (!g_progress_path[0])
        return;
    char buf[160];
    int n = snprintf(buf, sizeof buf, "elapsed=%.3f frames=%ld fps=%.2f\n", el,
                     g_frames_written, rate);
    if (n <= 0)
        return;
    int fd = open(g_progress_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0)
        return;
    ssize_t w = write(fd, buf, (size_t)n);
    (void)w;
    close(fd);
}

/* accepts 1500000, 1500k or 2M; returns -1 if it is not a sane bitrate */
static int parse_bitrate(const char *s)
{
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s)
        return -1;
    if (*end == 'k' || *end == 'K')
        v *= 1000.0;
    else if (*end == 'm' || *end == 'M')
        v *= 1000000.0;
    else if (*end)
        return -1;
    if (v < 1000 || v > 100000000)
        return -1;
    return (int)v;
}

int main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "rec")) {
        fprintf(stderr,
                "usage: kcap rec [options] <out> <seconds> <fps> [size]\n"
                "  <seconds>  0 or less records until stopped (see below)\n"
                "  --mp4      encode H.264 on the device (Venus VPU) instead of\n"
                "             appending raw frames, so <out> is a finished MP4\n"
                "  --bitrate=N  encoder bitrate in bit/s for --mp4; accepts a k or M\n"
                "             suffix (e.g. --bitrate=800k). Default %d.\n"
                "  --progress[=N]  every N seconds (default 1) report elapsed time on\n"
                "             stderr and in <out>.progress\n"
                "  raw out: packed 240x320 RGB565LE frames (~4.5 MB/s at 29 fps),\n"
                "           encode with\n"
                "    ffmpeg -f rawvideo -pixel_format rgb565le -video_size 240x320 \\\n"
                "           -framerate 29 -i out.raw -pix_fmt yuv420p out.mp4\n"
                "  stopping an open-ended recording: send SIGINT/SIGTERM/SIGHUP, or\n"
                "  create the file <out>.stop. Either way the recording is finished\n"
                "  cleanly (an MP4 still gets its moov atom).\n",
                ENC_BITRATE_DEFAULT);
        return 2;
    }

    /* --mp4 and --bitrate may appear anywhere after "rec"; the rest are
       positional */
    int mp4 = 0;
    int bitrate = ENC_BITRATE_DEFAULT;
    int bitrate_set = 0;
    int progress_ivl = 0;
    const char *pos[4] = { NULL, NULL, NULL, NULL };
    int npos = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--mp4")) {
            mp4 = 1;
            continue;
        }
        const char *br = NULL;
        if (!strncmp(argv[i], "--bitrate=", 10))
            br = argv[i] + 10;
        else if (!strcmp(argv[i], "--bitrate") && i + 1 < argc)
            br = argv[++i];
        if (br) {
            bitrate = parse_bitrate(br);
            bitrate_set = 1;
            if (bitrate < 0) {
                fprintf(stderr, "kcap: bad bitrate '%s' (use e.g. 800k, 1500000, 2M)\n", br);
                return 2;
            }
            continue;
        }
        if (!strncmp(argv[i], "--progress=", 11)) {
            progress_ivl = atoi(argv[i] + 11);
            if (progress_ivl < 0)
                progress_ivl = 0;
            continue;
        }
        if (!strcmp(argv[i], "--progress")) {
            progress_ivl = 1;
            continue;
        }
        if (npos < 4)
            pos[npos++] = argv[i];
    }

    const char *outpath =
        npos > 0 ? pos[0] : (mp4 ? "/data/local/tmp/kcap.mp4" : "/data/local/tmp/kcap.raw");
    double secs = npos > 1 ? atof(pos[1]) : 5;
    double fps = npos > 2 ? atof(pos[2]) : 29;
    unsigned long want = npos > 3 ? strtoul(pos[3], NULL, 0) : SCR_BUF_SIZE;
    if (fps <= 0)
        fps = 29;
    g_mp4 = mp4;
    g_fps = fps;
    g_bitrate = bitrate;
    if (bitrate_set && !mp4)
        fprintf(stderr, "kcap: --bitrate only applies to --mp4, ignoring it\n");

    /* a real FIFO: the target writes into it, we read frames out of memory */
    mkdir(FIFO_DIR, 0771); /* no-op if it already exists */
    unlink(FIFO_PATH);     /* drop whatever a killed run left behind */
    if (mkfifo(FIFO_PATH, 0666)) {
        perror("mkfifo " FIFO_PATH);
        return 1;
    }
    g_fifo_made = 1;
    atexit(fifo_remove);
    signal(SIGINT, on_stop_signal);
    signal(SIGTERM, on_stop_signal);
    signal(SIGHUP, on_stop_signal);
    chmod(FIFO_PATH, 0666);
    g_fifo_rd = open(FIFO_PATH, O_RDONLY | O_NONBLOCK);
    if (g_fifo_rd < 0) {
        perror("open fifo (read)");
        return 1;
    }

    /* <out>.stop stops an open-ended recording; drop a stale one first so a
       leftover file cannot end this run immediately */
    if (strlen(outpath) + 6 < sizeof g_stop_path) {
        snprintf(g_stop_path, sizeof g_stop_path, "%s.stop", outpath);
        unlink(g_stop_path);
    }
    if (progress_ivl > 0 && strlen(outpath) + 10 < sizeof g_progress_path) {
        snprintf(g_progress_path, sizeof g_progress_path, "%s.progress", outpath);
        unlink(g_progress_path);
    }
    g_progress_ivl = progress_ivl;

    if (g_mp4) {
        if (enc_open(outpath) < 0)
            return 1;
    } else {
        g_out_fd = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (g_out_fd < 0) {
            perror(outpath);
            return 1;
        }
    }

    struct bufref bufs[MAX_BUFS];
    int nb = 0, fifo_wr = -1;
    unsigned long scratch = 0;
    if (setup(bufs, &nb, &fifo_wr, &scratch, want) < 0)
        return 1;

    g_nbufs = nb;
    g_bufsize = bufs[0].size;
    for (int i = 0; i < nb; i++) {
        g_prev[i] = (uint8_t *)calloc(1, g_bufsize);
        g_cur[i] = (uint8_t *)malloc(g_bufsize);
        if (!g_prev[i] || !g_cur[i]) {
            fprintf(stderr, "kcap: out of memory\n");
            return 1;
        }
    }

    pthread_t thr;
    if (pthread_create(&thr, NULL, reader_main, NULL)) {
        fprintf(stderr, "kcap: cannot start reader thread\n");
        return 1;
    }

    /* a positive <seconds> bounds the recording; 0 or less (and inf) means
       record until a stop request arrives, reported as -1 */
    long target_frames;
    if (secs > 0 && secs < 1e9) {
        target_frames = (long)(secs * fps);
        if (target_frames < 1)
            target_frames = 1;
    } else {
        target_frames = -1;
    }
    if (target_frames < 0)
        fprintf(stderr, "kcap: recording until stopped "
                        "(SIGINT/SIGTERM/SIGHUP, or touch %s)\n",
                g_stop_path[0] ? g_stop_path : "<out>.stop");
    double period = 1.0 / fps, start = now_seconds();
    g_t_start = start;
    g_t_next_report = start + g_progress_ivl;
    long sent = 0;
    while (!stop_requested() && (target_frames < 0 || g_frames_written < target_frames)) {
        if (grab(bufs, nb, fifo_wr, scratch) < 0) {
            /* the HAL restarted - re-attach and re-open everything */
            if (g_mp4) {
                fprintf(stderr, "kcap: composer went away, ending the recording\n");
                break;
            }
            fprintf(stderr, "kcap: composer went away, reconnecting\n");
            g_stop = 1;
            pthread_join(thr, NULL);
            g_stop = 0;
            close(fifo_wr);
            if (setup(bufs, &nb, &fifo_wr, &scratch, want) < 0)
                break;
            g_nbufs = nb;
            g_bufsize = bufs[0].size;
            pthread_create(&thr, NULL, reader_main, NULL);
        }
        sent++;
        if (g_progress_ivl > 0)
            report_progress();
        double next = start + sent * period, t = now_seconds();
        if (next > t) {
            struct timespec ts;
            ts.tv_sec = 0;
            ts.tv_nsec = (long)((next - t) * 1e9);
            if (ts.tv_nsec > 0)
                nanosleep(&ts, NULL);
        }
    }

    g_stop = 1;
    pthread_join(thr, NULL);
    double el = now_seconds() - start;
    teardown(bufs, nb, fifo_wr);
    if (g_progress_path[0])
        unlink(g_progress_path);
    if (g_mp4)
        enc_close();
    else
        close(g_out_fd);
    fprintf(stderr, "kcap: %ld frames written in %.2fs (%.1f fps), %ld grabs%s\n",
            g_frames_written, el, el > 0 ? g_frames_written / el : 0, sent,
            g_stop_req ? " [stopped on request]" : "");
    return 0;
}
