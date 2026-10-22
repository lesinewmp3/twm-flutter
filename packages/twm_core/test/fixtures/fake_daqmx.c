/* Fake NI-DAQmx library for tests (C signatures of NIDAQmx.h): one analog
 * input task with continuous sampling producing a 50 Hz sine per channel in
 * real time; the calls are logged.
 *   cc -shared -fPIC -O2 -o libfakedaqmx.so fake_daqmx.c -lm */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef void *TaskHandle;
typedef int32_t int32;
typedef uint32_t uInt32;
typedef uint64_t uInt64;
typedef double float64;
typedef uInt32 bool32;

static struct {
  int created, started, channels;
  double rate, t0;
  uInt64 read;
  char log[2048];
} T;

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}
static void logf_(const char *t) {
  strncat(T.log, t, sizeof T.log - strlen(T.log) - 2);
  strcat(T.log, ";");
}
const char *fakeLog(void) { return T.log; }

int32 DAQmxCreateTask(const char *name, TaskHandle *task) {
  memset(&T, 0, sizeof T);
  T.created = 1;
  *task = (TaskHandle)&T;
  logf_(name[0] ? name : "CreateTask");
  return 0;
}
int32 DAQmxCreateAIVoltageChan(TaskHandle task, const char *phys, const char *name, int32 term, float64 min, float64 max,
                               int32 units, const char *scale) {
  char t[256];
  (void)task; (void)name;
  snprintf(t, sizeof t, "AIVoltage(%s,%d,%g,%g,%d,%s)", phys, term, min, max, units, scale ? scale : "null");
  logf_(t);
  T.channels = 1;
  for (const char *p = phys; *p; p++) T.channels += *p == ',';
  return 0;
}
int32 DAQmxCfgSampClkTiming(TaskHandle task, const char *src, float64 rate, int32 edge, int32 mode, uInt64 samps) {
  char t[160];
  (void)task;
  snprintf(t, sizeof t, "Timing(%s,%g,%d,%d,%llu)", src, rate, edge, mode, (unsigned long long)samps);
  logf_(t);
  T.rate = rate;
  return 0;
}
int32 DAQmxSetSampClkTimebaseSrc(TaskHandle task, const char *src) {
  char t[160];
  (void)task;
  snprintf(t, sizeof t, "TimebaseSrc(%s)", src);
  logf_(t);
  return 0;
}
int32 DAQmxSetSampClkTimebaseRate(TaskHandle task, float64 rate) {
  char t[64];
  (void)task;
  snprintf(t, sizeof t, "TimebaseRate(%g)", rate);
  logf_(t);
  return 0;
}
int32 DAQmxStartTask(TaskHandle task) { (void)task; T.started = 1; T.t0 = now(); logf_("Start"); return 0; }
int32 DAQmxStopTask(TaskHandle task) { (void)task; T.started = 0; logf_("Stop"); return 0; }
int32 DAQmxClearTask(TaskHandle task) { (void)task; logf_("Clear"); return 0; }
int32 DAQmxGetExtendedErrorInfo(char *buf, uInt32 size) { snprintf(buf, size, "fake DAQmx error"); return 0; }
int32 DAQmxGetReadTotalSampPerChanAcquired(TaskHandle task, uInt64 *n) {
  (void)task;
  *n = (uInt64)((now() - T.t0) * T.rate);
  return 0;
}
int32 DAQmxReadAnalogF64(TaskHandle task, int32 n, float64 timeout, bool32 fill, float64 *data, uInt32 size, int32 *got,
                         bool32 *reserved) {
  (void)task; (void)reserved;
  if (!T.started) return -200000;
  if (fill != 1 || size < (uInt32)(n * T.channels)) return -200229;
  double deadline = now() + timeout;
  while ((now() - T.t0) * T.rate < T.read + n) {
    if (now() > deadline) return -200284; /* timeout */
    struct timespec d = {0, 200000};
    nanosleep(&d, NULL);
  }
  for (int i = 0; i < n; i++)
    for (int c = 0; c < T.channels; c++)
      data[i * T.channels + c] = 0.4 * sin(2 * M_PI * 50 * (double)(T.read + i) / T.rate + c);
  T.read += n;
  *got = n;
  return 0;
}
