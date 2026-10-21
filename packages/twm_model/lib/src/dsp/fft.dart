/// FFT of any length: mixed radix (4, 2, 3, 5 and generic small primes)
/// Stockham autosort, Bluestein chirp-z only for lengths with a prime factor
/// above [Fft.maxRadix]. Twiddle factors are computed directly (not by long
/// recurrences), so the rounding error grows only with log(n).
library;

import 'dart:math' as math;
import 'dart:typed_data';

class Fft {
  /// Largest prime factor handled by the generic butterfly (O(p^2)).
  static const maxRadix = 61;

  /// In-place complex FFT, [re]/[im] length must be a power of two.
  static void radix2(Float64List re, Float64List im, {bool inverse = false}) {
    final n = re.length;
    if (n <= 1) return;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    final sign = inverse ? 1.0 : -1.0;
    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final ang = sign * 2 * math.pi / len;
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var k = 0; k < half; k++) {
          if (k & 31 == 0 && k > 0) {
            // resync the twiddle recurrence (bounded rounding error)
            cr = math.cos(ang * k);
            ci = math.sin(ang * k);
          }
          final a = i + k, b = a + half;
          final xr = re[b] * cr - im[b] * ci;
          final xi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }

  /// Radices of the mixed radix plan of [n], or null if [n] has a prime
  /// factor above [maxRadix] (Bluestein is used then).
  static List<int>? plan(int n) {
    final f = <int>[];
    var m = n;
    while (m % 4 == 0) {
      f.add(4);
      m ~/= 4;
    }
    if (m % 2 == 0) {
      f.add(2);
      m ~/= 2;
    }
    for (var p = 3; p * p <= m; p += 2) {
      while (m % p == 0) {
        f.add(p);
        m ~/= p;
      }
    }
    if (m > 1) f.add(m);
    return f.any((p) => p > maxRadix) ? null : f;
  }

  /// Complex forward FFT of any length. Returns (re, im); inputs are kept.
  static (Float64List, Float64List) transform(Float64List xr, [Float64List? xi]) {
    final n = xr.length;
    final re = Float64List.fromList(xr);
    final im = xi == null ? Float64List(n) : Float64List.fromList(xi);
    if (n <= 1) return (re, im);
    final radices = plan(n);
    if (radices == null) return _bluestein(re, im);
    return _stockham(re, im, radices);
  }

  /// Complex inverse FFT of any length (normalized by 1/n).
  static (Float64List, Float64List) inverse(Float64List xr, Float64List xi) {
    final n = xr.length;
    final ni = Float64List(n);
    for (var i = 0; i < n; i++) {
      ni[i] = -xi[i];
    }
    final (re, im) = transform(xr, ni);
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] = -im[i] / n;
    }
    return (re, im);
  }

  /// FFT of a real signal: bins 0..n~/2 (one sided). Even [n] uses a half
  /// length complex FFT (about twice faster than [transform]).
  static (Float64List, Float64List) real(Float64List x) {
    final n = x.length;
    final h = n ~/ 2 + 1;
    if (n < 4 || n.isOdd) {
      final (re, im) = transform(x);
      return (Float64List.sublistView(re, 0, h), Float64List.sublistView(im, 0, h));
    }
    final m = n ~/ 2;
    final zr = Float64List(m), zi = Float64List(m);
    for (var k = 0; k < m; k++) {
      zr[k] = x[2 * k];
      zi[k] = x[2 * k + 1];
    }
    final radices = plan(m);
    final (cr, ci) = radices == null ? _bluestein(zr, zi) : _stockham(zr, zi, radices);
    final re = Float64List(h), im = Float64List(h);
    // X[k] = E[k] + e^(-2 pi i k/n) O[k], E/O from Z[k] and conj(Z[m-k])
    final ang = -2 * math.pi / n;
    final w1r = math.cos(ang), w1i = math.sin(ang);
    var wr = 1.0, wi = 0.0;
    for (var k = 0; k <= m; k++) {
      if (k & 31 == 0 && k > 0) {
        wr = math.cos(ang * k);
        wi = math.sin(ang * k);
      }
      final a = k == m ? 0 : k, b = k == 0 ? 0 : m - k;
      final zkr = cr[a], zki = ci[a];
      final zcr = cr[b], zci = -ci[b]; // conj(Z[m-k])
      final er = 0.5 * (zkr + zcr), ei = 0.5 * (zki + zci);
      // O = -i/2 (Z[k] - conj(Z[m-k]))
      final dr = zkr - zcr, di = zki - zci;
      final or = 0.5 * di, oi = -0.5 * dr;
      re[k] = er + wr * or - wi * oi;
      im[k] = ei + wr * oi + wi * or;
      final nwr = wr * w1r - wi * w1i;
      wi = wr * w1i + wi * w1r;
      wr = nwr;
    }
    return (re, im);
  }

  // ---------------------------------------------------------------- core --

  /// Stockham autosort DIF: for each radix p (sub length nn = p*m, stride s)
  ///   y[q + s(p j + r)] = w^(j r) * sum_k x[q + s(j + k m)] * e^(-2 pi i k r/p)
  /// with w = e^(-2 pi i/nn); the output ends in natural order.
  static (Float64List, Float64List) _stockham(Float64List re, Float64List im, List<int> radices) {
    final n = re.length;
    var xr = re, xi = im;
    var yr = Float64List(n), yi = Float64List(n);
    var nn = n, s = 1;
    for (final p in radices) {
      switch (p) {
        case 4:
          _stage4(xr, xi, yr, yi, nn, s);
        case 2:
          _stage2(xr, xi, yr, yi, nn, s);
        case 3:
          _stage3(xr, xi, yr, yi, nn, s);
        case 5:
          _stage5(xr, xi, yr, yi, nn, s);
        default:
          _stageGeneric(xr, xi, yr, yi, nn, s, p);
      }
      final tr = xr, ti = xi;
      xr = yr;
      xi = yi;
      yr = tr;
      yi = ti;
      nn ~/= p;
      s *= p;
    }
    return (xr, xi);
  }

  static void _stage2(Float64List xr, Float64List xi, Float64List yr, Float64List yi, int nn, int s) {
    final m = nn >> 1, sm = s * m;
    for (var j = 0; j < m; j++) {
      final th = -2 * math.pi * j / nn;
      final w1r = math.cos(th), w1i = math.sin(th);
      final i0 = s * j, o0 = 2 * s * j;
      for (var q = 0; q < s; q++) {
        final a = i0 + q, o = o0 + q;
        final a0r = xr[a], a0i = xi[a], a1r = xr[a + sm], a1i = xi[a + sm];
        yr[o] = a0r + a1r;
        yi[o] = a0i + a1i;
        final br = a0r - a1r, bi = a0i - a1i;
        yr[o + s] = br * w1r - bi * w1i;
        yi[o + s] = br * w1i + bi * w1r;
      }
    }
  }

  static void _stage4(Float64List xr, Float64List xi, Float64List yr, Float64List yi, int nn, int s) {
    final m = nn >> 2, sm = s * m;
    for (var j = 0; j < m; j++) {
      final th = -2 * math.pi * j / nn;
      final w1r = math.cos(th), w1i = math.sin(th);
      final w2r = w1r * w1r - w1i * w1i, w2i = 2 * w1r * w1i;
      final w3r = w2r * w1r - w2i * w1i, w3i = w2r * w1i + w2i * w1r;
      final i0 = s * j, o0 = 4 * s * j;
      for (var q = 0; q < s; q++) {
        final a = i0 + q, o = o0 + q;
        final a0r = xr[a], a0i = xi[a];
        final a1r = xr[a + sm], a1i = xi[a + sm];
        final a2r = xr[a + 2 * sm], a2i = xi[a + 2 * sm];
        final a3r = xr[a + 3 * sm], a3i = xi[a + 3 * sm];
        final t0r = a0r + a2r, t0i = a0i + a2i;
        final t1r = a0r - a2r, t1i = a0i - a2i;
        final t2r = a1r + a3r, t2i = a1i + a3i;
        final t3r = a1r - a3r, t3i = a1i - a3i;
        yr[o] = t0r + t2r;
        yi[o] = t0i + t2i;
        // b1 = t1 - i t3, b2 = t0 - t2, b3 = t1 + i t3
        final b1r = t1r + t3i, b1i = t1i - t3r;
        final b2r = t0r - t2r, b2i = t0i - t2i;
        final b3r = t1r - t3i, b3i = t1i + t3r;
        yr[o + s] = b1r * w1r - b1i * w1i;
        yi[o + s] = b1r * w1i + b1i * w1r;
        yr[o + 2 * s] = b2r * w2r - b2i * w2i;
        yi[o + 2 * s] = b2r * w2i + b2i * w2r;
        yr[o + 3 * s] = b3r * w3r - b3i * w3i;
        yi[o + 3 * s] = b3r * w3i + b3i * w3r;
      }
    }
  }

  static void _stage3(Float64List xr, Float64List xi, Float64List yr, Float64List yi, int nn, int s) {
    const c = 0.86602540378443864676; // sin(2 pi/3)
    final m = nn ~/ 3, sm = s * m;
    for (var j = 0; j < m; j++) {
      final th = -2 * math.pi * j / nn;
      final w1r = math.cos(th), w1i = math.sin(th);
      final w2r = w1r * w1r - w1i * w1i, w2i = 2 * w1r * w1i;
      final i0 = s * j, o0 = 3 * s * j;
      for (var q = 0; q < s; q++) {
        final a = i0 + q, o = o0 + q;
        final a0r = xr[a], a0i = xi[a];
        final a1r = xr[a + sm], a1i = xi[a + sm];
        final a2r = xr[a + 2 * sm], a2i = xi[a + 2 * sm];
        final t1r = a1r + a2r, t1i = a1i + a2i;
        final t2r = a1r - a2r, t2i = a1i - a2i;
        yr[o] = a0r + t1r;
        yi[o] = a0i + t1i;
        final m1r = a0r - 0.5 * t1r, m1i = a0i - 0.5 * t1i;
        // -i c t2
        final m2r = c * t2i, m2i = -c * t2r;
        final b1r = m1r + m2r, b1i = m1i + m2i;
        final b2r = m1r - m2r, b2i = m1i - m2i;
        yr[o + s] = b1r * w1r - b1i * w1i;
        yi[o + s] = b1r * w1i + b1i * w1r;
        yr[o + 2 * s] = b2r * w2r - b2i * w2i;
        yi[o + 2 * s] = b2r * w2i + b2i * w2r;
      }
    }
  }

  static void _stage5(Float64List xr, Float64List xi, Float64List yr, Float64List yi, int nn, int s) {
    const c1 = 0.30901699437494742410, c2 = -0.80901699437494742410; // cos(2pi/5), cos(4pi/5)
    const s1 = 0.95105651629515357212, s2 = 0.58778525229247312917; // sin(2pi/5), sin(4pi/5)
    final m = nn ~/ 5, sm = s * m;
    for (var j = 0; j < m; j++) {
      final th = -2 * math.pi * j / nn;
      final w1r = math.cos(th), w1i = math.sin(th);
      final w2r = w1r * w1r - w1i * w1i, w2i = 2 * w1r * w1i;
      final w3r = w2r * w1r - w2i * w1i, w3i = w2r * w1i + w2i * w1r;
      final w4r = w2r * w2r - w2i * w2i, w4i = 2 * w2r * w2i;
      final i0 = s * j, o0 = 5 * s * j;
      for (var q = 0; q < s; q++) {
        final a = i0 + q, o = o0 + q;
        final a0r = xr[a], a0i = xi[a];
        final a1r = xr[a + sm], a1i = xi[a + sm];
        final a2r = xr[a + 2 * sm], a2i = xi[a + 2 * sm];
        final a3r = xr[a + 3 * sm], a3i = xi[a + 3 * sm];
        final a4r = xr[a + 4 * sm], a4i = xi[a + 4 * sm];
        final t1r = a1r + a4r, t1i = a1i + a4i;
        final t2r = a2r + a3r, t2i = a2i + a3i;
        final t3r = a1r - a4r, t3i = a1i - a4i;
        final t4r = a2r - a3r, t4i = a2i - a3i;
        yr[o] = a0r + t1r + t2r;
        yi[o] = a0i + t1i + t2i;
        final m1r = a0r + c1 * t1r + c2 * t2r, m1i = a0i + c1 * t1i + c2 * t2i;
        final m2r = a0r + c2 * t1r + c1 * t2r, m2i = a0i + c2 * t1i + c1 * t2i;
        final u1r = s1 * t3r + s2 * t4r, u1i = s1 * t3i + s2 * t4i;
        final u2r = s2 * t3r - s1 * t4r, u2i = s2 * t3i - s1 * t4i;
        // b1 = m1 - i u1, b4 = m1 + i u1, b2 = m2 - i u2, b3 = m2 + i u2
        final b1r = m1r + u1i, b1i = m1i - u1r;
        final b4r = m1r - u1i, b4i = m1i + u1r;
        final b2r = m2r + u2i, b2i = m2i - u2r;
        final b3r = m2r - u2i, b3i = m2i + u2r;
        yr[o + s] = b1r * w1r - b1i * w1i;
        yi[o + s] = b1r * w1i + b1i * w1r;
        yr[o + 2 * s] = b2r * w2r - b2i * w2i;
        yi[o + 2 * s] = b2r * w2i + b2i * w2r;
        yr[o + 3 * s] = b3r * w3r - b3i * w3i;
        yi[o + 3 * s] = b3r * w3i + b3i * w3r;
        yr[o + 4 * s] = b4r * w4r - b4i * w4i;
        yi[o + 4 * s] = b4r * w4i + b4i * w4r;
      }
    }
  }

  static void _stageGeneric(Float64List xr, Float64List xi, Float64List yr, Float64List yi, int nn, int s, int p) {
    final m = nn ~/ p, sm = s * m;
    final cr = Float64List(p), ci = Float64List(p); // e^(-2 pi i k/p)
    for (var k = 0; k < p; k++) {
      cr[k] = math.cos(-2 * math.pi * k / p);
      ci[k] = math.sin(-2 * math.pi * k / p);
    }
    final ar = Float64List(p), ai = Float64List(p);
    final wr = Float64List(p), wi = Float64List(p);
    for (var j = 0; j < m; j++) {
      for (var r = 0; r < p; r++) {
        final th = -2 * math.pi * ((j * r) % nn) / nn;
        wr[r] = math.cos(th);
        wi[r] = math.sin(th);
      }
      final i0 = s * j, o0 = p * s * j;
      for (var q = 0; q < s; q++) {
        final a = i0 + q, o = o0 + q;
        for (var k = 0; k < p; k++) {
          ar[k] = xr[a + k * sm];
          ai[k] = xi[a + k * sm];
        }
        for (var r = 0; r < p; r++) {
          var br = 0.0, bi = 0.0;
          var idx = 0;
          for (var k = 0; k < p; k++) {
            br += ar[k] * cr[idx] - ai[k] * ci[idx];
            bi += ar[k] * ci[idx] + ai[k] * cr[idx];
            idx += r;
            if (idx >= p) idx -= p;
          }
          yr[o + r * s] = br * wr[r] - bi * wi[r];
          yi[o + r * s] = br * wi[r] + bi * wr[r];
        }
      }
    }
  }

  /// Bluestein chirp-z for lengths with a large prime factor; the
  /// convolution runs on a 2^a 3^b 5^c length (smallest above 2n-1).
  static (Float64List, Float64List) _bluestein(Float64List re, Float64List im) {
    final n = re.length;
    var m = 2 * n - 1;
    while (!_smooth(m)) {
      m++;
    }
    // chirp e^(-i pi k^2/n), k^2 mod 2n kept exact by integer recurrence
    final wr = Float64List(n), wi = Float64List(n);
    var kk = 0;
    for (var k = 0; k < n; k++) {
      final a = math.pi * kk / n;
      wr[k] = math.cos(a);
      wi[k] = -math.sin(a);
      kk = (kk + 2 * k + 1) % (2 * n);
    }
    final ar = Float64List(m), ai = Float64List(m);
    for (var k = 0; k < n; k++) {
      ar[k] = re[k] * wr[k] - im[k] * wi[k];
      ai[k] = re[k] * wi[k] + im[k] * wr[k];
    }
    final br = Float64List(m), bi = Float64List(m);
    br[0] = wr[0];
    bi[0] = -wi[0];
    for (var k = 1; k < n; k++) {
      br[k] = br[m - k] = wr[k];
      bi[k] = bi[m - k] = -wi[k];
    }
    final plan = Fft.plan(m)!;
    final (fa, fai) = _stockham(ar, ai, plan);
    final (fb, fbi) = _stockham(br, bi, plan);
    // inverse FFT of the product via conjugation
    for (var k = 0; k < m; k++) {
      final r = fa[k] * fb[k] - fai[k] * fbi[k];
      final i = fa[k] * fbi[k] + fai[k] * fb[k];
      fa[k] = r;
      fai[k] = -i;
    }
    final (cr, ci) = _stockham(fa, fai, plan);
    final outR = Float64List(n), outI = Float64List(n);
    for (var k = 0; k < n; k++) {
      final r = cr[k] / m, i = -ci[k] / m;
      outR[k] = r * wr[k] - i * wi[k];
      outI[k] = r * wi[k] + i * wr[k];
    }
    return (outR, outI);
  }

  static bool _smooth(int m) {
    for (final p in const [2, 3, 5]) {
      while (m % p == 0) {
        m ~/= p;
      }
    }
    return m == 1;
  }
}
