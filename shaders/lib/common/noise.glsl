#ifndef ASTRA_NOISE_GLSL
#define ASTRA_NOISE_GLSL

#include "/lib/common/math.glsl"

/*
 * AstraRealism - Noise and dithering.
 *
 * Temporal effects need noise that is decorrelated both across the screen and
 * across frames, otherwise TAA turns the pattern into visible crawling. The
 * blue-noise + golden-ratio-per-frame combination below is the standard fix.
 */

//==============================================================================
// HASHES
//==============================================================================

// Integer hash, from Jarzynski & Olano, "Hash Functions for GPU Rendering"
// (JCGT 2020). Better avalanche behaviour than the usual sin()-based hashes and
// no dependency on trig precision, which varies between drivers.
uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float hashToFloat(uint h) {
    // Take the top 24 bits so the result is uniform in [0,1).
    return float(h >> 8) * (1.0 / 16777216.0);
}

float hash1(uint seed) { return hashToFloat(pcgHash(seed)); }

vec2 hash2(uint seed) {
    uint h = pcgHash(seed);
    return vec2(hashToFloat(h), hashToFloat(pcgHash(h)));
}

vec3 hash3(uint seed) {
    uint h0 = pcgHash(seed);
    uint h1 = pcgHash(h0);
    uint h2 = pcgHash(h1);
    return vec3(hashToFloat(h0), hashToFloat(h1), hashToFloat(h2));
}

// Cheap float hashes for cases where distribution quality matters less than
// instruction count (wave detail, grain).
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float hash1(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

vec3 hash3(vec3 p) {
    p = vec3(dot(p, vec3(127.1, 311.7, 74.7)),
             dot(p, vec3(269.5, 183.3, 246.1)),
             dot(p, vec3(113.5, 271.9, 124.6)));
    return fract(sin(p) * 43758.5453123);
}

//==============================================================================
// VALUE & GRADIENT NOISE
//==============================================================================

// Quintic fade. Its first and second derivatives vanish at the endpoints, so
// tiled noise has no visible grid creases the way a cubic fade does.
vec3 quinticFade(vec3 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
vec2 quinticFade(vec2 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = quinticFade(f);

    float a = hash1(i);
    float b = hash1(i + vec2(1.0, 0.0));
    float c = hash1(i + vec2(0.0, 1.0));
    float d = hash1(i + vec2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float valueNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = quinticFade(f);

    float n000 = hash1(i + vec3(0.0, 0.0, 0.0));
    float n100 = hash1(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash1(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash1(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash1(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash1(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash1(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash1(i + vec3(1.0, 1.0, 1.0));

    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float gradientNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = quinticFade(f);

    #define ASTRA_GRAD(o) dot(hash3(i + (o)) * 2.0 - 1.0, f - (o))

    float n000 = ASTRA_GRAD(vec3(0.0, 0.0, 0.0));
    float n100 = ASTRA_GRAD(vec3(1.0, 0.0, 0.0));
    float n010 = ASTRA_GRAD(vec3(0.0, 1.0, 0.0));
    float n110 = ASTRA_GRAD(vec3(1.0, 1.0, 0.0));
    float n001 = ASTRA_GRAD(vec3(0.0, 0.0, 1.0));
    float n101 = ASTRA_GRAD(vec3(1.0, 0.0, 1.0));
    float n011 = ASTRA_GRAD(vec3(0.0, 1.0, 1.0));
    float n111 = ASTRA_GRAD(vec3(1.0, 1.0, 1.0));

    #undef ASTRA_GRAD

    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z) * 0.5 + 0.5;
}

//==============================================================================
// WORLEY / CELLULAR
//
// Inverted Worley noise is what gives volumetric clouds their billowy edges.
//==============================================================================

float worleyNoise(vec3 p, float cellCount) {
    p *= cellCount;
    vec3 i = floor(p);
    vec3 f = fract(p);

    float minDist = 1.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                vec3 offset = vec3(float(x), float(y), float(z));
                // Wrap the cell coordinate so the field tiles at `cellCount`.
                vec3 cell = mod(i + offset, cellCount);
                vec3 point = offset + hash3(cell) - f;
                minDist = min(minDist, dot(point, point));
            }
        }
    }

    return 1.0 - saturate(sqrt(minDist));
}

//==============================================================================
// FRACTAL BROWNIAN MOTION
//==============================================================================

float fbm(vec3 p, int octaves, float lacunarity, float gain) {
    float sum = 0.0;
    float amplitude = 1.0;
    float normalization = 0.0;

    for (int i = 0; i < octaves; i++) {
        sum += gradientNoise(p) * amplitude;
        normalization += amplitude;
        p *= lacunarity;
        amplitude *= gain;
    }

    return sum / max(normalization, ASTRA_EPSILON);
}

float fbmWorley(vec3 p, int octaves, float lacunarity, float gain) {
    float sum = 0.0;
    float amplitude = 1.0;
    float normalization = 0.0;
    float cells = 4.0;

    for (int i = 0; i < octaves; i++) {
        sum += worleyNoise(p, cells) * amplitude;
        normalization += amplitude;
        cells *= lacunarity;
        amplitude *= gain;
    }

    return sum / max(normalization, ASTRA_EPSILON);
}

//==============================================================================
// TEMPORAL DITHERING
//==============================================================================

/*
 * Interleaved gradient noise (Jimenez, "Next Generation Post Processing in
 * Call of Duty: Advanced Warfare", 2014). Cheap, and its spectrum is good
 * enough that TAA resolves it cleanly.
 */
float interleavedGradientNoise(vec2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

/*
 * Same, animated per frame. Advancing by the golden ratio rather than a
 * random offset keeps successive frames maximally spread, so the temporal
 * average converges faster and low sample counts look less blotchy.
 */
float interleavedGradientNoise(vec2 pixel, int frame) {
    pixel += float(frame % 64) * 5.588238;
    return interleavedGradientNoise(pixel);
}

// Advance a [0,1) value by the golden ratio, wrapping. Used to decorrelate
// a blue-noise lookup across frames without destroying its spatial spectrum.
float goldenRatioAdvance(float x, int frame) {
    return fract(x + float(frame) * 0.61803398874989484820);
}

/*
 * R2 low-discrepancy sequence (Roberts, 2018). Two dimensions, no table, and
 * a lower star discrepancy than Halton for the sample counts we use.
 */
vec2 r2Sequence(int index) {
    // Plastic constant: the real root of x^3 = x + 1.
    const float g = 1.32471795724474602596;
    const vec2 alpha = vec2(1.0 / g, 1.0 / (g * g));
    return fract(0.5 + alpha * float(index));
}

// Halton sequence, used for TAA jitter where an exactly known period helps.
float halton(int index, int base) {
    float result = 0.0;
    float f = 1.0 / float(base);
    int i = index;

    while (i > 0) {
        result += f * float(i % base);
        i /= base;
        f /= float(base);
    }

    return result;
}

#endif // ASTRA_NOISE_GLSL
