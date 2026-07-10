/* qcamd_testclient — validates qcamd: connect, read frame-ready msgs, save one frame from shm. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define QCAMD_SHM  "/tmp/qcamd.shm"
#define QCAMD_SOCK "/tmp/qcamd.sock"
#define SLOT0_OFF  4096u
#define MAX_FRAME  (1280*1024*2)
struct qcamd_hdr { uint32_t magic,width,height,fourcc,frame_size,num_slots,seq,pad; };
struct frame_msg { uint32_t seq, slot; };

int main(int argc, char **argv) {
    int fd, shm_fd, i, want = (argc>1)?atoi(argv[1]):6;
    uint8_t *shm; struct qcamd_hdr *hdr; struct sockaddr_un a;
    struct frame_msg m;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&a,0,sizeof(a)); a.sun_family=AF_UNIX; strncpy(a.sun_path,QCAMD_SOCK,sizeof(a.sun_path)-1);
    if (connect(fd,(struct sockaddr*)&a,sizeof(a))<0){ perror("connect"); return 1; }
    printf("client: connected\n");
    shm_fd = open(QCAMD_SHM, O_RDONLY);
    if (shm_fd<0){ perror("open shm"); return 2; }
    shm = (uint8_t*)mmap(0, SLOT0_OFF + (size_t)4*MAX_FRAME, PROT_READ, MAP_SHARED, shm_fd, 0);
    if (shm==MAP_FAILED){ perror("mmap"); return 2; }
    hdr = (struct qcamd_hdr*)shm;

    for (i=0;i<want;i++) {
        if (read(fd,&m,sizeof(m))!=(int)sizeof(m)){ printf("client: read end\n"); break; }
        printf("client: frame seq=%u slot=%u  hdr %ux%u sz=%u magic=0x%08x\n",
               m.seq,m.slot,hdr->width,hdr->height,hdr->frame_size,hdr->magic);
        if (i==want-1 && hdr->frame_size) {
            FILE *f=fopen("/tmp/qcamd_frame.nv12","wb");
            if (f){ fwrite(shm+SLOT0_OFF+(size_t)m.slot*MAX_FRAME,1,hdr->frame_size,f); fclose(f);
                    printf("client: wrote /tmp/qcamd_frame.nv12 (%u bytes)\n",hdr->frame_size); }
        }
    }
    close(fd);
    printf("client: done\n");
    return 0;
}
