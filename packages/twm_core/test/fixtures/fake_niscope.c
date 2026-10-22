/* Fake NI-SCOPE + NI-TClk library for tests (real C signatures of niScope.h,
 * niTClk.h). Sessions record the calls and produce a sine per channel.
 * Single shot: the record is ready at once. A software reference trigger is
 * never sent, so the card acquires continuously (NI "Fetch Forever"): data
 * are fetched behind the read pointer as they are produced in real time.
 * A record longer than the onboard memory is refused at Commit/Initiate.
 *   cc -shared -fPIC -O2 -o libfakeniscope.so fake_niscope.c -lm */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef int32_t ViStatus;
typedef uint32_t ViSession;
typedef uint16_t ViBoolean;
typedef int32_t ViInt32;
typedef double ViReal64;

struct niScope_wfmInfo {
  ViReal64 absoluteInitialX, relativeInitialX, xIncrement;
  ViInt32 actualSamples;
  ViReal64 offset, gain, reserved1, reserved2;
};

#define MEMORY (8 * 1024 * 1024) /* samples per channel */
#define ERR (-1074118000)

typedef struct {
  int used, software, readPointer, initiated, committed, disabled, acqType;
  double fs, refPos, holdoff, delay, range[2], t0;
  int32_t record;
  int64_t fetched;
  char log[4096];
} S;

static S ss[8];
static char lastError[256];

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}
static void logf_(S *s, const char *t) {
  strncat(s->log, t, sizeof s->log - strlen(s->log) - 2);
  strcat(s->log, ";");
}
static ViStatus fail(const char *m) { snprintf(lastError, sizeof lastError, "%s", m); return ERR; }

/* test access: call log of session vi, e.g. "Commit;Initiate;" */
const char *fakeLog(ViSession vi) { return ss[vi].log; }

ViStatus niScope_init(const char *rsrc, ViBoolean idq, ViBoolean reset, ViSession *vi) {
  (void)idq; (void)reset;
  for (int i = 1; i < 8; i++) {
    if (!ss[i].used) {
      memset(&ss[i], 0, sizeof(S));
      ss[i].used = 1;
      ss[i].fs = 1e6;
      ss[i].record = 1000;
      snprintf(ss[i].log, sizeof ss[i].log, "init(%s);", rsrc);
      *vi = (ViSession)i;
      return 0;
    }
  }
  return fail("too many sessions");
}
ViStatus niScope_close(ViSession vi) { ss[vi].used = 0; return 0; }
ViStatus niScope_reset(ViSession vi) { logf_(&ss[vi], "reset"); return 0; }
ViStatus niScope_Abort(ViSession vi) { ss[vi].initiated = 0; logf_(&ss[vi], "Abort"); return 0; }
static ViStatus checkMemory(S *s) {
  return s->record > MEMORY ? fail("The record length exceeds the onboard memory.") : 0;
}
ViStatus niScope_Commit(ViSession vi) { S *s = &ss[vi]; s->committed = 1; s->disabled = 0; logf_(s, "Commit"); return checkMemory(s); }
ViStatus niScope_Disable(ViSession vi) { ss[vi].disabled = 1; logf_(&ss[vi], "Disable"); return 0; }
ViStatus niScope_InitiateAcquisition(ViSession vi) {
  S *s = &ss[vi];
  ViStatus st = checkMemory(s);
  if (st < 0) return st;
  s->initiated = 1; s->fetched = 0; s->t0 = now();
  logf_(s, "Initiate");
  return 0;
}
ViStatus niScope_ConfigureVertical(ViSession vi, const char *ch, ViReal64 range, ViReal64 offset, ViInt32 coupling,
                                   ViReal64 probe, ViBoolean enabled) {
  char t[160];
  snprintf(t, sizeof t, "Vertical(%s,%g,%g,%d,%g,%d)", ch, range, offset, coupling, probe, enabled);
  logf_(&ss[vi], t);
  int c = ch[0] == '1';
  ss[vi].range[c] = range;
  return 0;
}
ViStatus niScope_ConfigureChanCharacteristics(ViSession vi, const char *ch, ViReal64 z, ViReal64 f) {
  char t[128];
  snprintf(t, sizeof t, "Chan(%s,%g,%g)", ch, z, f);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_ConfigureHorizontalTiming(ViSession vi, ViReal64 fs, ViInt32 n, ViReal64 refPos, ViInt32 records,
                                           ViBoolean realtime) {
  char t[128];
  snprintf(t, sizeof t, "Horizontal(%g,%d,%g,%d,%d)", fs, n, refPos, records, realtime);
  logf_(&ss[vi], t);
  ss[vi].fs = 60e6 / floor(60e6 / fs + 0.5);
  ss[vi].record = n;
  ss[vi].refPos = refPos;
  return 0;
}
ViStatus niScope_ConfigureTriggerImmediate(ViSession vi) { ss[vi].software = 0; logf_(&ss[vi], "TrigImmediate"); return 0; }
ViStatus niScope_ConfigureTriggerSoftware(ViSession vi, ViReal64 holdoff, ViReal64 delay) {
  char t[96];
  snprintf(t, sizeof t, "TrigSoftware(%g,%g)", holdoff, delay);
  logf_(&ss[vi], t);
  ss[vi].software = 1;
  return 0;
}
ViStatus niScope_ConfigureTriggerEdge(ViSession vi, const char *src, ViReal64 level, ViInt32 slope, ViInt32 coupling,
                                      ViReal64 holdoff, ViReal64 delay) {
  char t[160];
  snprintf(t, sizeof t, "TrigEdge(%s,%g,%d,%d,%g,%g)", src, level, slope, coupling, holdoff, delay);
  logf_(&ss[vi], t);
  ss[vi].software = 0;
  return 0;
}
ViStatus niScope_ConfigureTriggerHysteresis(ViSession vi, const char *src, ViReal64 level, ViReal64 hyst, ViInt32 slope,
                                            ViInt32 coupling, ViReal64 holdoff, ViReal64 delay) {
  char t[160];
  snprintf(t, sizeof t, "TrigHyst(%s,%g,%g,%d,%d,%g,%g)", src, level, hyst, slope, coupling, holdoff, delay);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_ConfigureTriggerDigital(ViSession vi, const char *src, ViInt32 slope, ViReal64 holdoff, ViReal64 delay) {
  char t[128];
  snprintf(t, sizeof t, "TrigDigital(%s,%d,%g,%g)", src, slope, holdoff, delay);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_ConfigureTriggerWindow(ViSession vi, const char *src, ViReal64 lo, ViReal64 hi, ViInt32 mode,
                                        ViInt32 coupling, ViReal64 holdoff, ViReal64 delay) {
  char t[160];
  snprintf(t, sizeof t, "TrigWindow(%s,%g,%g,%d,%d,%g,%g)", src, lo, hi, mode, coupling, holdoff, delay);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_ConfigureAcquisition(ViSession vi, ViInt32 type) {
  char t[64];
  snprintf(t, sizeof t, "Acquisition(%d)", type);
  logf_(&ss[vi], t);
  ss[vi].acqType = type;
  return 0;
}
ViStatus niScope_SetAttributeViReal64(ViSession vi, const char *ch, uint32_t attr, ViReal64 v) {
  char t[96];
  snprintf(t, sizeof t, "SetReal(%u,%g)", attr, v);
  logf_(&ss[vi], t); (void)ch;
  return 0;
}
ViStatus niScope_SetAttributeViInt32(ViSession vi, const char *ch, uint32_t attr, ViInt32 v) {
  char t[96];
  snprintf(t, sizeof t, "SetInt(%u,%d)", attr, v);
  logf_(&ss[vi], t); (void)ch;
  if (attr == 1150077) ss[vi].readPointer = v == 388;
  return 0;
}
ViStatus niScope_SetAttributeViString(ViSession vi, const char *ch, uint32_t attr, const char *v) {
  char t[128];
  snprintf(t, sizeof t, "SetString(%u,%s)", attr, v);
  logf_(&ss[vi], t); (void)ch;
  return 0;
}
ViStatus niScope_GetAttributeViReal64(ViSession vi, const char *ch, uint32_t attr, ViReal64 *v) {
  (void)vi; (void)ch; (void)attr; *v = 0; return 0;
}
ViStatus niScope_GetError(ViSession vi, ViStatus *code, ViInt32 size, char *desc) {
  (void)vi;
  if (code) *code = ERR;
  snprintf(desc, size, "%s", lastError);
  return 0;
}
ViStatus niScope_CalSelfCalibrate(ViSession vi, const char *ch, ViInt32 option) {
  char t[64];
  snprintf(t, sizeof t, "SelfCal(%s,%d)", ch, option);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_ExportSignal(ViSession vi, ViInt32 signal, const char *id, const char *term) {
  char t[128];
  snprintf(t, sizeof t, "Export(%d,%s,%s)", signal, id, term);
  logf_(&ss[vi], t);
  return 0;
}
ViStatus niScope_AcquisitionStatus(ViSession vi, ViInt32 *status) {
  *status = ss[vi].initiated && !ss[vi].software ? 1 : 0;
  return 0;
}
ViStatus niScope_SampleRate(ViSession vi, ViReal64 *fs) { *fs = ss[vi].fs; return 0; }

/* sample i of channel c of session vi: 1 V sine of 1 kHz, phase by channel and card */
static int32_t sample(ViSession vi, int c, int64_t i, double fs) {
  return (int32_t)lround(1e6 * sin(2 * M_PI * 1e3 * i / fs + c + 2 * (vi - 1)));
}

static ViStatus fetch(ViSession vi, const char *chList, ViReal64 timeout, ViInt32 n, int32_t *w16or32, int is16,
                      struct niScope_wfmInfo *info) {
  S *s = &ss[vi];
  if (!s->initiated) return fail("No acquisition in progress.");
  int chans[2], nc = 0;
  for (const char *p = chList; *p; p++)
    if (*p == '0' || *p == '1') chans[nc++] = *p - '0';
  int64_t start = s->readPointer ? s->fetched : 0;
  if (s->readPointer) {
    if (!s->software && start + n > s->record) return fail("Attempt to fetch beyond the end of the record.");
    double deadline = now() + timeout;
    while ((now() - s->t0) * s->fs < start + n) {
      if (now() > deadline) return fail("Maximum time exceeded before the operation completed.");
      struct timespec d = {0, 200000};
      nanosleep(&d, NULL);
    }
    if ((now() - s->t0) * s->fs - start > MEMORY) return fail("Samples were overwritten.");
  } else if (n > s->record) {
    return fail("Attempt to fetch beyond the end of the record.");
  }
  for (int k = 0; k < nc; k++) {
    for (int i = 0; i < n; i++) {
      int32_t v = sample(vi, chans[k], start + i, s->fs);
      if (is16) ((int16_t *)w16or32)[k * n + i] = (int16_t)(v >> 8);
      else w16or32[k * n + i] = v;
    }
    info[k].absoluteInitialX = 1.0e9;
    info[k].relativeInitialX = (start - s->refPos / 100.0 * s->record) / s->fs;
    info[k].xIncrement = 1 / s->fs;
    info[k].actualSamples = n;
    info[k].offset = 0.25e-6;
    info[k].gain = 1e-6;
    info[k].reserved1 = info[k].reserved2 = -1;
  }
  s->fetched = start + n;
  return 0;
}
ViStatus niScope_FetchBinary32(ViSession vi, const char *ch, ViReal64 timeout, ViInt32 n, int32_t *wfm,
                               struct niScope_wfmInfo *info) {
  return fetch(vi, ch, timeout, n, wfm, 0, info);
}
ViStatus niScope_FetchBinary16(ViSession vi, const char *ch, ViReal64 timeout, ViInt32 n, int16_t *wfm,
                               struct niScope_wfmInfo *info) {
  return fetch(vi, ch, timeout, n, (int32_t *)wfm, 1, info);
}

/* NI-TClk */
ViStatus niTClk_ConfigureForHomogeneousTriggers(uint32_t count, ViSession *sessions) {
  for (uint32_t i = 0; i < count; i++) logf_(&ss[sessions[i]], "TClkHomogeneous");
  return 0;
}
ViStatus niTClk_Synchronize(uint32_t count, ViSession *sessions, ViReal64 minTime) {
  for (uint32_t i = 0; i < count; i++) {
    char t[64];
    snprintf(t, sizeof t, "TClkSync(%g)", minTime);
    logf_(&ss[sessions[i]], t);
  }
  return 0;
}
ViStatus niTClk_Initiate(uint32_t count, ViSession *sessions) {
  for (uint32_t i = 0; i < count; i++) {
    ViStatus st = niScope_InitiateAcquisition(sessions[i]);
    if (st < 0) return st;
  }
  return 0;
}
ViStatus niTClk_GetExtendedErrorInfo(char *buf, uint32_t size) {
  snprintf(buf, size, "%s", lastError);
  return 0;
}
