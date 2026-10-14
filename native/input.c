// SPDX-License-Identifier: GPL-3.0-or-later
// Global input: evdev (works on every compositor, needs read access to
// /dev/input), X11 key grabs, uinput key injection and X11 window info.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <X11/XKBlib.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include "internal.h"

#define UINPUT_NAME "fboard virtual input"
#define MAX_DEVS 64
#define BITS_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_LONG - 1) / BITS_LONG)
#define TEST_BIT(bit, arr) (((arr)[(bit) / BITS_LONG] >> ((bit) % BITS_LONG)) & 1)

// ============================================================== uinput
static int ui_fd = -1;
static pthread_mutex_t ui_lock = PTHREAD_MUTEX_INITIALIZER;

int fb_uinput_open(void) {
  pthread_mutex_lock(&ui_lock);
  if (ui_fd >= 0) {
    pthread_mutex_unlock(&ui_lock);
    return 0;
  }
  int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) {
    int e = errno;
    pthread_mutex_unlock(&ui_lock);
    return -e;
  }
  ioctl(fd, UI_SET_EVBIT, EV_KEY);
  ioctl(fd, UI_SET_EVBIT, EV_SYN);
  ioctl(fd, UI_SET_EVBIT, EV_MSC);
  ioctl(fd, UI_SET_MSCBIT, MSC_SCAN);
  ioctl(fd, UI_SET_EVBIT, EV_REL);
  ioctl(fd, UI_SET_RELBIT, REL_X);
  ioctl(fd, UI_SET_RELBIT, REL_Y);
  ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
  ioctl(fd, UI_SET_RELBIT, REL_HWHEEL);
  for (int k = 1; k < 256; k++) ioctl(fd, UI_SET_KEYBIT, k);
  for (int k = BTN_LEFT; k <= BTN_TASK; k++) ioctl(fd, UI_SET_KEYBIT, k);
  struct uinput_setup us;
  memset(&us, 0, sizeof us);
  us.id.bustype = BUS_VIRTUAL;
  us.id.vendor = 0xfb0a;
  us.id.product = 0x0001;
  snprintf(us.name, sizeof us.name, UINPUT_NAME);
  if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
    int e = errno;
    close(fd);
    pthread_mutex_unlock(&ui_lock);
    return -e;
  }
  ui_fd = fd;
  pthread_mutex_unlock(&ui_lock);
  usleep(100000);  // let the compositor pick up the device
  return 0;
}

void fb_uinput_close(void) {
  pthread_mutex_lock(&ui_lock);
  if (ui_fd >= 0) {
    ioctl(ui_fd, UI_DEV_DESTROY);
    close(ui_fd);
    ui_fd = -1;
  }
  pthread_mutex_unlock(&ui_lock);
}

int fb_uinput_emit_raw(int type, int code, int value) {
  if (ui_fd < 0) return -ENODEV;
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type;
  ev.code = code;
  ev.value = value;
  return write(ui_fd, &ev, sizeof ev) == sizeof ev ? 0 : -errno;
}

int fb_uinput_key(int32_t code, int32_t value) {
  pthread_mutex_lock(&ui_lock);
  int r = fb_uinput_emit_raw(EV_KEY, code, value);
  if (r == 0) r = fb_uinput_emit_raw(EV_SYN, SYN_REPORT, 0);
  pthread_mutex_unlock(&ui_lock);
  return r;
}

// ============================================================== evdev
typedef struct {
  int fd;
  int keyboard;
  int grabbed;
  char path[300];
} evdev_dev;

static pthread_t ev_thread;
static atomic_int ev_running;
static int ev_wake[2] = {-1, -1};
static evdev_dev devs[MAX_DEVS];
static int ndevs;
static pthread_mutex_t ev_lock = PTHREAD_MUTEX_INITIALIZER;
static int ev_block = 0;
static int32_t* tbl_masks = NULL;
static int32_t* tbl_codes = NULL;
static int tbl_n = 0;
static int tbl_sided = 0;
static int mods = 0;
static unsigned char swallowed[KEY_CNT];

static int mod_bit(int code) {
  switch (code) {
    case KEY_LEFTCTRL: return FB_MOD_LCTRL;
    case KEY_RIGHTCTRL: return FB_MOD_RCTRL;
    case KEY_LEFTSHIFT: return FB_MOD_LSHIFT;
    case KEY_RIGHTSHIFT: return FB_MOD_RSHIFT;
    case KEY_LEFTALT: return FB_MOD_LALT;
    case KEY_RIGHTALT: return FB_MOD_RALT;
    case KEY_LEFTMETA: return FB_MOD_LMETA;
    case KEY_RIGHTMETA: return FB_MOD_RMETA;
  }
  return 0;
}

static int unsided(int m) {
  // fold right modifiers onto the left bits
  return (m | (m >> 1)) & (FB_MOD_LCTRL | FB_MOD_LSHIFT | FB_MOD_LALT | FB_MOD_LMETA);
}

static int table_match(int mask, int code) {
  for (int i = 0; i < tbl_n; i++) {
    if (tbl_codes[i] != code) continue;
    if (tbl_sided ? tbl_masks[i] == mask : unsided(tbl_masks[i]) == unsided(mask)) return 1;
  }
  return 0;
}

static void close_dev(int i) {
  if (devs[i].grabbed) ioctl(devs[i].fd, EVIOCGRAB, 0);
  close(devs[i].fd);
  devs[i] = devs[--ndevs];
}

static void apply_grab(evdev_dev* d) {
  int want = ev_block && d->keyboard && ui_fd >= 0;
  if (want == d->grabbed) return;
  if (ioctl(d->fd, EVIOCGRAB, want ? 1 : 0) == 0) d->grabbed = want;
}

static void try_open(const char* path) {
  if (ndevs >= MAX_DEVS) return;
  for (int i = 0; i < ndevs; i++)
    if (strcmp(devs[i].path, path) == 0) return;
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return;
  char name[256] = "";
  ioctl(fd, EVIOCGNAME(sizeof name), name);
  if (strcmp(name, UINPUT_NAME) == 0) {
    close(fd);
    return;
  }
  unsigned long evbits[NLONGS(EV_CNT)] = {0};
  unsigned long keybits[NLONGS(KEY_CNT)] = {0};
  ioctl(fd, EVIOCGBIT(0, sizeof evbits), evbits);
  if (!TEST_BIT(EV_KEY, evbits)) {
    close(fd);
    return;
  }
  ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keybits), keybits);
  int kbd = TEST_BIT(KEY_A, keybits) && TEST_BIT(KEY_Z, keybits) && TEST_BIT(KEY_ENTER, keybits);
  int mouse = TEST_BIT(BTN_LEFT, keybits) || TEST_BIT(BTN_SIDE, keybits);
  if (!kbd && !mouse && !TEST_BIT(KEY_F1, keybits)) {
    close(fd);
    return;
  }
  evdev_dev* d = &devs[ndevs++];
  d->fd = fd;
  d->keyboard = kbd;
  d->grabbed = 0;
  snprintf(d->path, sizeof d->path, "%s", path);
  apply_grab(d);
}

static void scan_devices(void) {
  DIR* dir = opendir("/dev/input");
  if (!dir) return;
  struct dirent* e;
  while ((e = readdir(dir))) {
    if (strncmp(e->d_name, "event", 5) != 0) continue;
    char p[300];
    snprintf(p, sizeof p, "/dev/input/%s", e->d_name);
    try_open(p);
  }
  closedir(dir);
}

static void handle_event(evdev_dev* d, struct input_event* ev) {
  int forward = d->grabbed;
  if (ev->type == EV_KEY && ev->code < KEY_CNT) {
    int code = ev->code;
    int mb = mod_bit(code);
    if (mb) {
      if (ev->value) mods |= mb;
      else mods &= ~mb;
    }
    if (ev->value == 1 && !mb) {
      if (ev_block && d->grabbed && table_match(mods, code)) swallowed[code] = 1;
    }
    if (swallowed[code]) {
      forward = 0;
      if (ev->value == 0) swallowed[code] = 0;
    }
    if (ev->value != 2) fb_emit(FB_EV_KEY, code, ev->value, mods);
  }
  if (forward) {
    pthread_mutex_lock(&ui_lock);
    fb_uinput_emit_raw(ev->type, ev->code, ev->value);
    pthread_mutex_unlock(&ui_lock);
  }
}

static void* ev_main(void* arg) {
  (void)arg;
  int ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (ino >= 0) inotify_add_watch(ino, "/dev/input", IN_CREATE | IN_ATTRIB);
  struct pollfd pfd[MAX_DEVS + 2];
  while (atomic_load(&ev_running)) {
    pthread_mutex_lock(&ev_lock);
    int n = 0;
    pfd[n].fd = ev_wake[0];
    pfd[n++].events = POLLIN;
    pfd[n].fd = ino;
    pfd[n++].events = POLLIN;
    for (int i = 0; i < ndevs; i++) {
      pfd[n].fd = devs[i].fd;
      pfd[n++].events = POLLIN;
    }
    int count = ndevs;
    pthread_mutex_unlock(&ev_lock);
    if (poll(pfd, n, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (pfd[0].revents) {
      char b[16];
      while (read(ev_wake[0], b, sizeof b) > 0) {
      }
    }
    pthread_mutex_lock(&ev_lock);
    if (pfd[1].revents & POLLIN) {
      char b[4096];
      while (read(ino, b, sizeof b) > 0) {
      }
      usleep(50000);  // udev needs a moment to fix permissions
      scan_devices();
    }
    for (int i = count - 1; i >= 0; i--) {
      if (i >= ndevs) continue;
      short re = pfd[i + 2].revents;
      if (re & (POLLERR | POLLHUP | POLLNVAL)) {
        close_dev(i);
        continue;
      }
      if (!(re & POLLIN)) continue;
      struct input_event evs[64];
      ssize_t r;
      while ((r = read(devs[i].fd, evs, sizeof evs)) > 0) {
        for (size_t k = 0; k < (size_t)r / sizeof(struct input_event); k++) handle_event(&devs[i], &evs[k]);
      }
      if (r < 0 && errno != EAGAIN) close_dev(i);
    }
    pthread_mutex_unlock(&ev_lock);
  }
  pthread_mutex_lock(&ev_lock);
  while (ndevs) close_dev(ndevs - 1);
  pthread_mutex_unlock(&ev_lock);
  if (ino >= 0) close(ino);
  return NULL;
}

int fb_evdev_start(void) {
  if (atomic_load(&ev_running)) return 0;
  // Check that we can read at least one device.
  pthread_mutex_lock(&ev_lock);
  scan_devices();
  int n = ndevs;
  pthread_mutex_unlock(&ev_lock);
  if (n == 0) {
    DIR* dir = opendir("/dev/input");
    if (dir) closedir(dir);
    return -EACCES;
  }
  if (pipe2(ev_wake, O_NONBLOCK | O_CLOEXEC) < 0) return -errno;
  atomic_store(&ev_running, 1);
  if (pthread_create(&ev_thread, NULL, ev_main, NULL) != 0) {
    atomic_store(&ev_running, 0);
    return -EAGAIN;
  }
  return 0;
}

void fb_evdev_stop(void) {
  if (!atomic_load(&ev_running)) return;
  atomic_store(&ev_running, 0);
  if (write(ev_wake[1], "x", 1) < 0) {
  }
  pthread_join(ev_thread, NULL);
  close(ev_wake[0]);
  close(ev_wake[1]);
  ev_wake[0] = ev_wake[1] = -1;
  mods = 0;
  memset(swallowed, 0, sizeof swallowed);
}

int fb_evdev_device_count(void) {
  pthread_mutex_lock(&ev_lock);
  int n = ndevs;
  pthread_mutex_unlock(&ev_lock);
  return n;
}

int fb_evdev_set_block(int on) {
  int r = 0;
  if (on) r = fb_uinput_open();
  pthread_mutex_lock(&ev_lock);
  ev_block = on && r == 0;
  for (int i = 0; i < ndevs; i++) apply_grab(&devs[i]);
  pthread_mutex_unlock(&ev_lock);
  return r;
}

void fb_evdev_set_table(const int32_t* masks, const int32_t* codes, int32_t n, int sided) {
  pthread_mutex_lock(&ev_lock);
  free(tbl_masks);
  free(tbl_codes);
  tbl_masks = malloc(sizeof(int32_t) * (n > 0 ? n : 1));
  tbl_codes = malloc(sizeof(int32_t) * (n > 0 ? n : 1));
  if (n > 0) {
    memcpy(tbl_masks, masks, sizeof(int32_t) * n);
    memcpy(tbl_codes, codes, sizeof(int32_t) * n);
  }
  tbl_n = n;
  tbl_sided = sided;
  pthread_mutex_unlock(&ev_lock);
}

// ============================================================== X11
static pthread_t x_thread;
static atomic_int x_running;
static int x_wake[2] = {-1, -1};
static Display* x_dpy;
static pthread_mutex_t x_lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t* x_masks = NULL;
static int32_t* x_codes = NULL;
static int x_n = 0;
static int x_dirty = 0;
static int32_t* x_grabbed_masks = NULL;
static int32_t* x_grabbed_codes = NULL;
static int x_grabbed_n = 0;

static int x_err_handler(Display* d, XErrorEvent* e) {
  (void)d, (void)e;
  return 0;  // ignore BadAccess from keys grabbed by someone else
}

static unsigned fb_to_x_mods(int m) {
  unsigned x = 0;
  if (m & (FB_MOD_LCTRL | FB_MOD_RCTRL)) x |= ControlMask;
  if (m & (FB_MOD_LSHIFT | FB_MOD_RSHIFT)) x |= ShiftMask;
  if (m & (FB_MOD_LALT | FB_MOD_RALT)) x |= Mod1Mask;
  if (m & (FB_MOD_LMETA | FB_MOD_RMETA)) x |= Mod4Mask;
  return x;
}

static int x_to_fb_mods(unsigned s) {
  int m = 0;
  if (s & ControlMask) m |= FB_MOD_LCTRL;
  if (s & ShiftMask) m |= FB_MOD_LSHIFT;
  if (s & Mod1Mask) m |= FB_MOD_LALT;
  if (s & Mod4Mask) m |= FB_MOD_LMETA;
  return m;
}

static int btn_to_x(int code) {
  switch (code) {
    case BTN_LEFT: return 1;
    case BTN_MIDDLE: return 2;
    case BTN_RIGHT: return 3;
    case BTN_SIDE: return 8;
    case BTN_EXTRA: return 9;
  }
  return 0;
}

static int x_to_btn(int b) {
  switch (b) {
    case 1: return BTN_LEFT;
    case 2: return BTN_MIDDLE;
    case 3: return BTN_RIGHT;
    case 8: return BTN_SIDE;
    case 9: return BTN_EXTRA;
  }
  return 0;
}

static void x_grab_one(int mask, int code, int grab) {
  Window root = DefaultRootWindow(x_dpy);
  unsigned base = fb_to_x_mods(mask);
  unsigned extras[4] = {0, LockMask, Mod2Mask, LockMask | Mod2Mask};
  int btn = btn_to_x(code);
  for (int k = 0; k < 4; k++) {
    if (btn) {
      if (grab)
        XGrabButton(x_dpy, btn, base | extras[k], root, False, ButtonPressMask | ButtonReleaseMask, GrabModeAsync,
                    GrabModeAsync, None, None);
      else
        XUngrabButton(x_dpy, btn, base | extras[k], root);
    } else {
      if (grab)
        XGrabKey(x_dpy, code + 8, base | extras[k], root, False, GrabModeAsync, GrabModeAsync);
      else
        XUngrabKey(x_dpy, code + 8, base | extras[k], root);
    }
  }
}

static void x_apply_table(void) {
  for (int i = 0; i < x_grabbed_n; i++) x_grab_one(x_grabbed_masks[i], x_grabbed_codes[i], 0);
  free(x_grabbed_masks);
  free(x_grabbed_codes);
  x_grabbed_masks = malloc(sizeof(int32_t) * (x_n + 1));
  x_grabbed_codes = malloc(sizeof(int32_t) * (x_n + 1));
  x_grabbed_n = x_n;
  for (int i = 0; i < x_n; i++) {
    x_grabbed_masks[i] = x_masks[i];
    x_grabbed_codes[i] = x_codes[i];
    x_grab_one(x_masks[i], x_codes[i], 1);
  }
  XSync(x_dpy, False);
}

static void* x_main(void* arg) {
  (void)arg;
  int xfd = ConnectionNumber(x_dpy);
  while (atomic_load(&x_running)) {
    pthread_mutex_lock(&x_lock);
    if (x_dirty) {
      x_apply_table();
      x_dirty = 0;
    }
    pthread_mutex_unlock(&x_lock);
    while (XPending(x_dpy)) {
      XEvent e;
      XNextEvent(x_dpy, &e);
      if (e.type == KeyPress || e.type == KeyRelease) {
        int code = (int)e.xkey.keycode - 8;
        fb_emit(FB_EV_KEY, code, e.type == KeyPress, x_to_fb_mods(e.xkey.state));
      } else if (e.type == ButtonPress || e.type == ButtonRelease) {
        int code = x_to_btn((int)e.xbutton.button);
        if (code) fb_emit(FB_EV_KEY, code, e.type == ButtonPress, x_to_fb_mods(e.xbutton.state));
      }
    }
    struct pollfd p[2] = {{xfd, POLLIN, 0}, {x_wake[0], POLLIN, 0}};
    if (poll(p, 2, -1) < 0 && errno != EINTR) break;
    if (p[1].revents) {
      char b[16];
      while (read(x_wake[0], b, sizeof b) > 0) {
      }
    }
  }
  pthread_mutex_lock(&x_lock);
  for (int i = 0; i < x_grabbed_n; i++) x_grab_one(x_grabbed_masks[i], x_grabbed_codes[i], 0);
  x_grabbed_n = 0;
  XSync(x_dpy, False);
  pthread_mutex_unlock(&x_lock);
  return NULL;
}

int fb_x11_start(void) {
  if (atomic_load(&x_running)) return 0;
  XInitThreads();
  x_dpy = XOpenDisplay(NULL);
  if (!x_dpy) return -ENODEV;
  XSetErrorHandler(x_err_handler);
  Bool sup;
  XkbSetDetectableAutoRepeat(x_dpy, True, &sup);
  if (pipe2(x_wake, O_NONBLOCK | O_CLOEXEC) < 0) return -errno;
  x_dirty = 1;
  atomic_store(&x_running, 1);
  if (pthread_create(&x_thread, NULL, x_main, NULL) != 0) {
    atomic_store(&x_running, 0);
    return -EAGAIN;
  }
  return 0;
}

void fb_x11_stop(void) {
  if (!atomic_load(&x_running)) return;
  atomic_store(&x_running, 0);
  if (write(x_wake[1], "x", 1) < 0) {
  }
  pthread_join(x_thread, NULL);
  close(x_wake[0]);
  close(x_wake[1]);
  XCloseDisplay(x_dpy);
  x_dpy = NULL;
}

void fb_x11_set_table(const int32_t* masks, const int32_t* codes, int32_t n) {
  pthread_mutex_lock(&x_lock);
  free(x_masks);
  free(x_codes);
  x_masks = malloc(sizeof(int32_t) * (n + 1));
  x_codes = malloc(sizeof(int32_t) * (n + 1));
  if (n > 0) {
    memcpy(x_masks, masks, sizeof(int32_t) * n);
    memcpy(x_codes, codes, sizeof(int32_t) * n);
  }
  x_n = n;
  x_dirty = 1;
  pthread_mutex_unlock(&x_lock);
  if (atomic_load(&x_running) && write(x_wake[1], "x", 1) < 0) {
  }
}

// Active window information (X11 / XWayland windows only).
static Display* info_dpy = NULL;

static unsigned char* get_prop(Display* d, Window w, Atom prop, Atom type, unsigned long* n) {
  Atom at;
  int af;
  unsigned long after;
  unsigned char* data = NULL;
  if (XGetWindowProperty(d, w, prop, 0, 1024, False, type, &at, &af, n, &after, &data) != Success) return NULL;
  return data;
}

int fb_x11_active_window(char* wm_class, int32_t len, int32_t* pid, int32_t* fullscreen) {
  if (!info_dpy) {
    XInitThreads();
    info_dpy = XOpenDisplay(NULL);
    if (!info_dpy) return -1;
    XSetErrorHandler(x_err_handler);
  }
  Display* d = info_dpy;
  Window root = DefaultRootWindow(d);
  unsigned long n = 0;
  unsigned char* data = get_prop(d, root, XInternAtom(d, "_NET_ACTIVE_WINDOW", False), XA_WINDOW, &n);
  if (!data || n == 0) {
    if (data) XFree(data);
    return -2;
  }
  Window w = *(Window*)data;
  XFree(data);
  if (!w) return -3;
  *pid = 0;
  data = get_prop(d, w, XInternAtom(d, "_NET_WM_PID", False), XA_CARDINAL, &n);
  if (data && n) *pid = (int32_t) * (unsigned long*)data;
  if (data) XFree(data);
  wm_class[0] = 0;
  XClassHint ch;
  if (XGetClassHint(d, w, &ch)) {
    snprintf(wm_class, len, "%s", ch.res_class ? ch.res_class : "");
    if (ch.res_name) XFree(ch.res_name);
    if (ch.res_class) XFree(ch.res_class);
  }
  *fullscreen = 0;
  Atom fs = XInternAtom(d, "_NET_WM_STATE_FULLSCREEN", False);
  data = get_prop(d, w, XInternAtom(d, "_NET_WM_STATE", False), XA_ATOM, &n);
  if (data) {
    for (unsigned long i = 0; i < n; i++)
      if (((Atom*)data)[i] == fs) *fullscreen = 1;
    XFree(data);
  }
  if (!*fullscreen) {
    // Borderless fullscreen: window covers the whole screen.
    XWindowAttributes a;
    if (XGetWindowAttributes(d, w, &a)) {
      int x, y;
      Window child;
      XTranslateCoordinates(d, w, root, 0, 0, &x, &y, &child);
      Screen* s = DefaultScreenOfDisplay(d);
      if (x <= 0 && y <= 0 && a.width >= WidthOfScreen(s) && a.height >= HeightOfScreen(s)) *fullscreen = 1;
    }
  }
  return 0;
}
