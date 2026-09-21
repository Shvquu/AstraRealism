#ifndef ASTRA_MATH_GLSL
#define ASTRA_MATH_GLSL

#include "/lib/common/constants.glsl"

/*
 * AstraRealism - Shared math helpers.
 *
 * Deliberately free of any rendering concepts so it can be included anywhere
 * without pulling in uniforms.
 */

//==============================================================================
// CLAMPING & INTERPOLATION
//==============================================================================

float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2  saturate(vec2  x) { return clamp(x, 0.0, 1.0); }
vec3  saturate(vec3  x) { return clamp(x, 0.0, 1.0); }
vec4  saturate(vec4  x) { return clamp(x, 0.0, 1.0); }

// Integer powers, written out because pow() with a constant exponent is both
// slower and less accurate than repeated multiplication on most drivers.
float pow2(float x) { return x * x; }
float pow3(float x) { return x * x * x; }
float pow4(float x) { float x2 = x * x; return x2 * x2; }
float pow5(float x) { float x2 = x * x; return x2 * x2 * x; }
vec2  pow2(vec2  x) { return x * x; }
vec3  pow2(vec3  x) { return x * x; }
vec3  pow3(vec3  x) { return x * x * x; }
vec3  pow4(vec3  x) { vec3 x2 = x * x; return x2 * x2; }
vec3  pow5(vec3  x) { vec3 x2 = x * x; return x2 * x2 * x; }

// Map x from [a,b] to [0,1], clamped.
float remap01(float x, float a, float b) {
    return saturate((x - a) / max(b - a, ASTRA_EPSILON));
}

// Map x from [inLow,inHigh] to [outLow,outHigh], clamped to the output range.
float remap(float x, float inLow, float inHigh, float outLow, float outHigh) {
    return mix(outLow, outHigh, remap01(x, inLow, inHigh));
}

// Framerate-independent exponential smoothing. `rate` is the fraction of the
// remaining gap closed per second.
float expSmooth(float current, float target, float rate, float dt) {
    return mix(current, target, 1.0 - exp(-rate * dt));
}
vec3 expSmooth(vec3 current, vec3 target, float rate, float dt) {
    return mix(current, target, 1.0 - exp(-rate * dt));
}

//==============================================================================
// VECTOR UTILITIES
//==============================================================================

float lengthSquared(vec2 v) { return dot(v, v); }
float lengthSquared(vec3 v) { return dot(v, v); }

float maxComponent(vec2 v) { return max(v.x, v.y); }
float maxComponent(vec3 v) { return max(v.x, max(v.y, v.z)); }
float minComponent(vec3 v) { return min(v.x, min(v.y, v.z)); }

// dot() clamped to the upper hemisphere, the form needed by nearly every BRDF.
float clampedDot(vec3 a, vec3 b) { return max(dot(a, b), 0.0); }

//==============================================================================
// ORTHONORMAL BASIS
//==============================================================================

/*
 * Branchless orthonormal basis from a unit vector.
 * Duff et al., "Building an Orthonormal Basis, Revisited" (JCGT 2017).
 * The sign trick avoids the singularity a naive cross-with-up would hit when
 * n points straight up or down.
 */
void buildOrthonormalBasis(vec3 n, out vec3 tangent, out vec3 bitangent) {
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float b = n.x * n.y * a;
    tangent   = vec3(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
    bitangent = vec3(b, s + n.y * n.y * a, -n.y);
}

// Rotate `v` around `axis` (must be unit length) by `angle` radians.
vec3 rotateAroundAxis(vec3 v, vec3 axis, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

// 2D rotation matrix.
mat2 rotationMatrix2(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat2(c, -s, s, c);
}

//==============================================================================
// SAMPLING
//==============================================================================

// Cosine-weighted hemisphere sample around +Z, from two uniform randoms.
// The cosine weight cancels the N.L term in the diffuse integral.
vec3 cosineWeightedHemisphere(vec2 xi) {
    float r = sqrt(xi.x);
    float phi = ASTRA_TAU * xi.y;
    return vec3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - xi.x)));
}

// Uniform point on a sphere.
vec3 uniformSphere(vec2 xi) {
    float z = 1.0 - 2.0 * xi.x;
    float r = sqrt(max(0.0, 1.0 - z * z));
    float phi = ASTRA_TAU * xi.y;
    return vec3(r * cos(phi), r * sin(phi), z);
}

// Uniform point in a disc, used for PCF/PCSS taps and bokeh.
vec2 uniformDisc(vec2 xi) {
    float r = sqrt(xi.x);
    float phi = ASTRA_TAU * xi.y;
    return vec2(r * cos(phi), r * sin(phi));
}

/*
 * Vogel disc: a deterministic spiral whose points are near-uniformly spaced.
 * Better than random taps for small sample counts because it has no clumping,
 * and rotating it per-pixel turns the residual pattern into noise.
 */
vec2 vogelDisc(int index, int count, float rotation) {
    float r = sqrt((float(index) + 0.5) / float(count));
    // 2.399963 rad is the golden angle, which maximises angular spread.
    float theta = float(index) * 2.39996322972865332 + rotation;
    return vec2(r * cos(theta), r * sin(theta));
}

//==============================================================================
// PHASE FUNCTIONS
//==============================================================================

// Rayleigh phase function for molecular scattering.
float rayleighPhase(float cosTheta) {
    return (3.0 / (16.0 * ASTRA_PI)) * (1.0 + cosTheta * cosTheta);
}

// Henyey-Greenstein phase function. g in (-1,1); positive is forward scattering.
float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return ASTRA_INV_TAU * 0.5 * (1.0 - g2) / max(denom * sqrt(denom), ASTRA_EPSILON);
}

/*
 * Cornette-Shanks: a Mie approximation that stays physically normalised and
 * behaves better than raw HG at grazing angles. Used for the atmosphere.
 */
float cornetteShanks(float cosTheta, float g) {
    float g2 = g * g;
    float num = 3.0 * (1.0 - g2) * (1.0 + cosTheta * cosTheta);
    float den = 8.0 * ASTRA_PI * (2.0 + g2) * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
    return num / max(den, ASTRA_EPSILON);
}

// Two-lobe HG: a forward lobe plus a weaker back lobe. Clouds need the back lobe
// to get the bright rim when the sun is behind them.
float dualHenyeyGreenstein(float cosTheta, float gForward, float gBackward, float blend) {
    return mix(henyeyGreenstein(cosTheta, gBackward),
               henyeyGreenstein(cosTheta, gForward), blend);
}

//==============================================================================
// INTERSECTION
//==============================================================================

/*
 * Ray-sphere intersection for a sphere centred at the origin.
 * Returns vec2(near, far) distances along the ray, or vec2(-1.0) on a miss.
 * Used for atmosphere and cloud-shell marching.
 */
vec2 raySphereIntersect(vec3 origin, vec3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0) return vec2(-1.0);
    float sqrtD = sqrt(discriminant);
    return vec2(-b - sqrtD, -b + sqrtD);
}

// Slab test against an axis-aligned box. Returns vec2(near, far); near > far
// means a miss.
vec2 rayAABBIntersect(vec3 origin, vec3 invDir, vec3 boxMin, vec3 boxMax) {
    vec3 t0 = (boxMin - origin) * invDir;
    vec3 t1 = (boxMax - origin) * invDir;
    vec3 tMin = min(t0, t1);
    vec3 tMax = max(t0, t1);
    return vec2(maxComponent(tMin), minComponent(tMax));
}

//==============================================================================
// COLOR SPACE
//==============================================================================

float luminance(vec3 linearColor) { return dot(linearColor, ASTRA_LUMA_709); }

// sRGB transfer functions. The piecewise form matters near black: a plain
// pow(x, 2.2) crushes dark texture detail noticeably.
vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92,
               pow((c + 0.055) / 1.055, vec3(2.4)),
               step(0.04045, c));
}
vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92,
               1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055,
               step(0.0031308, c));
}

/*
 * Approximate CCT (Kelvin) to linear RGB.
 * Planckian locus fit valid for roughly 1000K-15000K, normalised so that
 * 6500K returns white. Used for both block-light colour and white balance.
 */
vec3 blackbodyToRGB(float kelvin) {
    float t = clamp(kelvin, 1000.0, 15000.0) / 100.0;
    vec3 c;

    if (t <= 66.0) {
        c.r = 255.0;
        c.g = 99.4708025861 * log(t) - 161.1195681661;
        c.b = (t <= 19.0) ? 0.0 : (138.5177312231 * log(t - 10.0) - 305.0447927307);
    } else {
        c.r = 329.698727446 * pow(t - 60.0, -0.1332047592);
        c.g = 288.1221695283 * pow(t - 60.0, -0.0755148492);
        c.b = 255.0;
    }

    c = saturate(c / 255.0);
    return srgbToLinear(c);
}

//==============================================================================
// PACKING
//==============================================================================

// Pack two [0,1] floats into one, at 8 bits each. Safe in a 16-bit float target
// because the result never needs more than 16 bits of mantissa.
float pack2x8(vec2 v) {
    vec2 q = floor(saturate(v) * 255.0 + 0.5);
    return (q.x * 256.0 + q.y) / 65535.0;
}
vec2 unpack2x8(float packed) {
    float q = packed * 65535.0;
    float x = floor(q / 256.0);
    return vec2(x, q - x * 256.0) / 255.0;
}

#endif // ASTRA_MATH_GLSL
