/*
 * ethercat_bpf: raw EtherCAT frames for the BEAM on macOS.
 *
 * macOS has no AF_PACKET sockets. A program sends and receives whole Ethernet frames through a BPF
 * device, /dev/bpfN, which takes ioctl calls the BEAM cannot make. This program does that as an
 * Erlang port, a process of its own: EtherCAT.Bus.Transport.Bpf starts it with the name of the
 * interface, and the two talk over standard input and output in packets with a two-byte length.
 *
 *   to the BEAM:    'R' mac[6]     ready, with the hardware address of the interface
 *                   'F' frame      a frame that was received, from its Ethernet header on
 *                   'S' text       a frame could not be sent
 *                   'E' text       it could not start; it then ends with status 1
 *   from the BEAM:  frame          a frame to send, from its Ethernet header on
 *
 * Only frames of EtherType 0x88A4 are received, with or without one VLAN tag, and never the frames
 * this machine sent itself. It ends when its standard input is closed.
 *
 * Opening a BPF device needs read and write access to /dev/bpf*: root, or the group access_bpf that
 * Wireshark's ChmodBPF sets up.
 */

#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ETHERTYPE_ETHERCAT 0x88A4
#define ETHERTYPE_VLAN 0x8100
#define MAX_PACKET 65535

static int write_all(int fd, const void *data, size_t size) {
  const uint8_t *at = data;

  while (size > 0) {
    ssize_t written = write(fd, at, size);

    if (written < 0) {
      if (errno == EINTR) continue;
      return -1;
    }

    at += written;
    size -= (size_t)written;
  }

  return 0;
}

/* 1 when all of it was read, 0 at the end of the input, -1 on an error. */
static int read_all(int fd, void *data, size_t size) {
  uint8_t *at = data;

  while (size > 0) {
    ssize_t got = read(fd, at, size);

    if (got == 0) return 0;

    if (got < 0) {
      if (errno == EINTR) continue;
      return -1;
    }

    at += got;
    size -= (size_t)got;
  }

  return 1;
}

/* One packet to the BEAM: a tag and what goes with it. The BEAM is gone when it cannot be written. */
static void emit(char tag, const void *data, size_t size) {
  uint8_t head[3];

  if (size > MAX_PACKET - 1) size = MAX_PACKET - 1;

  head[0] = (uint8_t)((size + 1) >> 8);
  head[1] = (uint8_t)((size + 1) & 0xFF);
  head[2] = (uint8_t)tag;

  if (write_all(STDOUT_FILENO, head, sizeof head) < 0 ||
      write_all(STDOUT_FILENO, data, size) < 0)
    exit(0);
}

static void fail(const char *what) {
  char text[256];
  int length = snprintf(text, sizeof text, "%s: %s", what, strerror(errno));

  emit('E', text, (size_t)length);
  exit(1);
}

static int open_bpf(void) {
  char path[32];
  int denied = 0;

  for (int n = 0; n < 256; n++) {
    snprintf(path, sizeof path, "/dev/bpf%d", n);

    int fd = open(path, O_RDWR);
    if (fd >= 0) return fd;

    if (errno == EACCES || errno == EPERM) denied = 1;
    if (errno == ENOENT) break;
  }

  errno = denied ? EACCES : EBUSY;
  return -1;
}

/* The hardware address of the interface, 0 when it has none of six bytes. */
static int hardware_address(const char *name, uint8_t mac[6]) {
  struct ifaddrs *all;
  int found = 0;

  if (getifaddrs(&all) < 0) return 0;

  for (struct ifaddrs *each = all; each != NULL; each = each->ifa_next) {
    if (each->ifa_addr == NULL || each->ifa_addr->sa_family != AF_LINK) continue;
    if (strcmp(each->ifa_name, name) != 0) continue;

    struct sockaddr_dl *link = (struct sockaddr_dl *)each->ifa_addr;

    if (link->sdl_alen == 6) {
      memcpy(mac, LLADDR(link), 6);
      found = 1;
    }

    break;
  }

  freeifaddrs(all);
  return found;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    errno = EINVAL;
    fail("usage: ethercat_bpf INTERFACE");
  }

  const char *name = argv[1];

  if (strlen(name) >= IFNAMSIZ) {
    errno = ENAMETOOLONG;
    fail(name);
  }

  int bpf = open_bpf();
  if (bpf < 0) fail("cannot open a /dev/bpf device");

  /* The size of the buffer is set before the device is bound to an interface, and read back. */
  u_int size = 1 << 17;
  ioctl(bpf, BIOCSBLEN, &size);

  struct ifreq interface;
  memset(&interface, 0, sizeof interface);
  strlcpy(interface.ifr_name, name, sizeof interface.ifr_name);
  if (ioctl(bpf, BIOCSETIF, &interface) < 0) fail(name);

  u_int kind;
  if (ioctl(bpf, BIOCGDLT, &kind) < 0) fail("BIOCGDLT");

  if (kind != DLT_EN10MB) {
    errno = EPROTOTYPE;
    fail("not an Ethernet interface");
  }

  u_int on = 1, off = 0;
  /* A read gives a frame as soon as it has come, and not when the buffer is full. */
  if (ioctl(bpf, BIOCIMMEDIATE, &on) < 0) fail("BIOCIMMEDIATE");
  /* What is sent on the interface from this machine is not received here. The tests build a
     listener that does receive it, to see what the program sends without a second interface. */
#ifdef ETHERCAT_BPF_SEE_SENT
  if (ioctl(bpf, BIOCSSEESENT, &on) < 0) fail("BIOCSSEESENT");
  (void)off;
#else
  if (ioctl(bpf, BIOCSSEESENT, &off) < 0) fail("BIOCSSEESENT");
#endif
  /* The source address of a frame is sent as it was written. */
  if (ioctl(bpf, BIOCSHDRCMPLT, &on) < 0) fail("BIOCSHDRCMPLT");

  struct bpf_insn only_ethercat[] = {
      BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 12),
      BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_ETHERCAT, 3, 0),
      BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_VLAN, 0, 3),
      BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 16),
      BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ETHERTYPE_ETHERCAT, 0, 1),
      BPF_STMT(BPF_RET + BPF_K, (u_int)-1),
      BPF_STMT(BPF_RET + BPF_K, 0),
  };

  struct bpf_program filter = {
      .bf_len = sizeof only_ethercat / sizeof only_ethercat[0],
      .bf_insns = only_ethercat,
  };

  if (ioctl(bpf, BIOCSETF, &filter) < 0) fail("BIOCSETF");
  if (ioctl(bpf, BIOCGBLEN, &size) < 0) fail("BIOCGBLEN");

  uint8_t mac[6];

  if (!hardware_address(name, mac)) {
    errno = EADDRNOTAVAIL;
    fail("the interface has no hardware address");
  }

  uint8_t *received = malloc(size);
  uint8_t *sending = malloc(MAX_PACKET);

  if (received == NULL || sending == NULL) fail("malloc");

  emit('R', mac, sizeof mac);

  for (;;) {
    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(STDIN_FILENO, &ready);
    FD_SET(bpf, &ready);

    if (select(bpf + 1, &ready, NULL, NULL, NULL) < 0) {
      if (errno == EINTR) continue;
      return 2;
    }

    if (FD_ISSET(bpf, &ready)) {
      ssize_t got = read(bpf, received, size);

      if (got < 0 && errno != EINTR && errno != EAGAIN) return 2;

      /* One read may give several frames, each after a header that says how long it is. */
      for (uint8_t *at = received; got > 0 && at < received + got;) {
        struct bpf_hdr *head = (struct bpf_hdr *)at;

        emit('F', at + head->bh_hdrlen, head->bh_caplen);
        at += BPF_WORDALIGN(head->bh_hdrlen + head->bh_caplen);
      }
    }

    if (FD_ISSET(STDIN_FILENO, &ready)) {
      uint8_t length[2];

      if (read_all(STDIN_FILENO, length, sizeof length) <= 0) return 0;

      size_t frame = ((size_t)length[0] << 8) | length[1];

      if (read_all(STDIN_FILENO, sending, frame) <= 0) return 0;

      if (write(bpf, sending, frame) < 0) {
        const char *why = strerror(errno);
        emit('S', why, strlen(why));
      }
    }
  }
}
