/* Fake VISA library for tests: GPIB sessions behave like 3458A DMMs in the
 * digitizing mode (subset of commands). After TARM SGL a session produces
 * NRDGS readings in real time (TIMER period). Without reading memory (MEM OFF)
 * only a few readings fit in the output buffer: when the controller does not
 * read in time the session reports an overrun, like "TRIGGER TOO FAST". With
 * END ALWAYS every reading ends a viRead (EOI). Built by the tests:
 *   cc -shared -fPIC -O2 -o libfakevisa.so fake_visa.c -lpthread */
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TMO_ATTR 0x3FFF001AU
#define ERR_TMO ((int32_t)0xBFFF0015U)
#define ERR_IO ((int32_t)0xBFFF003EU)
#define MAXS 16
#define OUTBUF 64 /* readings the DMM holds without memory */

typedef struct {
  int used, sint, mem, end_always, armed, overrun;
  double timer, t0;
  long nrdgs, produced_read; /* readings already read */
  uint32_t tmo_ms;
  char resp[256];
  int resp_len;
  pthread_mutex_t mx;
} S;

static S ss[MAXS];
static long read_calls = 0;
static pthread_mutex_t gmx = PTHREAD_MUTEX_INITIALIZER;

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}

long fakeReadCalls(void) { return read_calls; }

int32_t viOpenDefaultRM(uint32_t *rm) { *rm = 1; return 0; }

int32_t viOpen(uint32_t rm, const char *name, uint32_t mode, uint32_t tmo, uint32_t *vi) {
  (void)rm; (void)name; (void)mode; (void)tmo;
  pthread_mutex_lock(&gmx);
  for (int i = 2; i < MAXS; i++) {
    if (!ss[i].used) {
      memset(&ss[i], 0, sizeof(S));
      ss[i].used = 1;
      ss[i].sint = 1;
      ss[i].end_always = 1;
      ss[i].timer = 1e-4;
      ss[i].tmo_ms = 2000;
      pthread_mutex_init(&ss[i].mx, NULL);
      *vi = (uint32_t)i;
      pthread_mutex_unlock(&gmx);
      return 0;
    }
  }
  pthread_mutex_unlock(&gmx);
  return ERR_IO;
}

int32_t viClose(uint32_t vi) { if (vi < MAXS) ss[vi].used = 0; return 0; }
int32_t viClear(uint32_t vi) {
  S *s = &ss[vi];
  pthread_mutex_lock(&s->mx);
  s->armed = 0; s->resp_len = 0;
  pthread_mutex_unlock(&s->mx);
  return 0;
}
int32_t viGpibControlREN(uint32_t vi, uint16_t m) { (void)vi; (void)m; return 0; }
int32_t viFindRsrc(uint32_t rm, const char *e, uint32_t *l, uint32_t *c, char *d) {
  (void)rm; (void)e; (void)l; (void)d; *c = 0; return ERR_IO;
}
int32_t viFindNext(uint32_t l, char *d) { (void)l; (void)d; return ERR_IO; }
int32_t viStatusDesc(uint32_t vi, int32_t st, char *d) {
  (void)vi;
  snprintf(d, 256, st == ERR_TMO ? "timeout" : (st == ERR_IO ? "I/O error (overrun: TRIGGER TOO FAST)" : "error %d"), st);
  return 0;
}
int32_t viSetAttribute(uint32_t vi, uint32_t attr, uintptr_t v) {
  if (vi < MAXS && attr == TMO_ATTR) ss[vi].tmo_ms = (uint32_t)v;
  return 0;
}

static void respond(S *s, const char *t) { s->resp_len = snprintf(s->resp, sizeof s->resp, "%s\r\n", t); }

static void command(S *s, char *c) {
  while (*c == ' ') c++;
  if (!strncmp(c, "ID?", 3)) respond(s, "HP3458A");
  else if (!strncmp(c, "CALSTR?", 7)) respond(s, "\"FAKE\"");
  else if (!strncmp(c, "ISCALE?", 7)) respond(s, "1.000000000E-04");
  else if (!strncmp(c, "ERRSTR?", 7)) respond(s, s->overrun ? "1,\"TRIGGER TOO FAST\"" : "0,\"NO ERROR\"");
  else if (!strncmp(c, "TEMP?", 5)) respond(s, "35.0");
  else if (!strncmp(c, "END ", 4)) s->end_always = strstr(c, "ALWAYS") != NULL;
  else if (!strncmp(c, "MEM ", 4)) s->mem = strstr(c, "OFF") == NULL;
  else if (!strncmp(c, "OFORMAT ", 8)) s->sint = strstr(c, "SINT") != NULL;
  else if (!strncmp(c, "TIMER ", 6)) s->timer = atof(c + 6);
  else if (!strncmp(c, "NRDGS ", 6)) s->nrdgs = atol(c + 6);
  else if (!strncmp(c, "TARM SGL", 8)) { s->armed = 1; s->overrun = 0; s->produced_read = 0; s->t0 = now(); }
  else if (!strncmp(c, "TARM HOLD", 9)) s->armed = 0;
}

int32_t viWrite(uint32_t vi, const uint8_t *buf, uint32_t n, uint32_t *ret) {
  S *s = &ss[vi];
  char tmp[1024];
  uint32_t k = n < sizeof tmp - 1 ? n : sizeof tmp - 1;
  memcpy(tmp, buf, k);
  tmp[k] = 0;
  pthread_mutex_lock(&s->mx);
  for (char *p = strtok(tmp, ";\n"); p; p = strtok(NULL, ";\n")) command(s, p);
  pthread_mutex_unlock(&s->mx);
  *ret = n;
  return 0;
}

/* reading i of session vi: sine, a different phase per session */
static int32_t sample(uint32_t vi, long i, double timer) {
  return (int32_t)lround(10000.0 * sin(2 * M_PI * 50.0 * i * timer + vi));
}

int32_t viRead(uint32_t vi, uint8_t *buf, uint32_t cnt, uint32_t *ret) {
  S *s = &ss[vi];
  __sync_fetch_and_add(&read_calls, 1);
  *ret = 0;
  double deadline = now() + s->tmo_ms * 1e-3;
  pthread_mutex_lock(&s->mx);
  if (s->resp_len > 0) {
    uint32_t k = (uint32_t)s->resp_len < cnt ? (uint32_t)s->resp_len : cnt;
    memcpy(buf, s->resp, k);
    memmove(s->resp, s->resp + k, s->resp_len - k);
    s->resp_len -= k;
    *ret = k;
    pthread_mutex_unlock(&s->mx);
    return 0;
  }
  int bps = s->sint ? 2 : 4;
  uint32_t got = 0;
  while (got + bps <= cnt) {
    if (!s->armed) break;
    long produced = (long)((now() - s->t0) / s->timer);
    if (produced > s->nrdgs) produced = s->nrdgs;
    if (!s->mem && produced - s->produced_read > OUTBUF) s->overrun = 1;
    if (s->overrun) { pthread_mutex_unlock(&s->mx); *ret = got; return ERR_IO; }
    if (s->produced_read < produced) {
      int32_t v = sample(vi, s->produced_read++, s->timer);
      if (bps == 2) { buf[got] = (uint8_t)(v >> 8); buf[got + 1] = (uint8_t)v; }
      else { buf[got] = (uint8_t)(v >> 24); buf[got + 1] = (uint8_t)(v >> 16); buf[got + 2] = (uint8_t)(v >> 8); buf[got + 3] = (uint8_t)v; }
      got += bps;
      if (s->end_always) break; /* EOI after every reading */
      continue;
    }
    if (s->produced_read >= s->nrdgs) break;
    if (now() > deadline) { pthread_mutex_unlock(&s->mx); *ret = got; return ERR_TMO; }
    pthread_mutex_unlock(&s->mx);
    usleep(200);
    pthread_mutex_lock(&s->mx);
  }
  pthread_mutex_unlock(&s->mx);
  *ret = got;
  return got > 0 ? 0 : ERR_TMO;
}
