#ifndef ASTRA_CONSTANTS_GLSL
#define ASTRA_CONSTANTS_GLSL

/*
 * AstraRealism - Physical and numerical constants.
 *
 * Every value here has a stated origin. Nothing in this pack should use a bare
 * numeric literal whose meaning is not obvious from context; put it here with a
 * comment instead.
 */

//==============================================================================
// MATHEMATICAL
//==============================================================================

const float ASTRA_PI        = 3.14159265358979323846;
const float ASTRA_TAU       = 6.28318530717958647692; // 2*pi
const float ASTRA_HALF_PI   = 1.57079632679489661923;
const float ASTRA_INV_PI    = 0.31830988618379067154; // 1/pi
const float ASTRA_INV_TAU   = 0.15915494309189533577; // 1/(2*pi)
const float ASTRA_SQRT2     = 1.41421356237309504880;
const float ASTRA_GOLDEN    = 1.61803398874989484820;

// Smallest offset that reliably avoids division by zero in half-float math.
const float ASTRA_EPSILON   = 1e-6;

// Upper clamp for HDR radiance. RGBA16F tops out near 65504; staying an order
// of magnitude below that keeps intermediate sums from overflowing to Inf.
const float ASTRA_MAX_RADIANCE = 4096.0;

//==============================================================================
// COLORIMETRY
//==============================================================================

// Luminance weights for Rec.709 / sRGB primaries (linear light).
const vec3 ASTRA_LUMA_709 = vec3(0.2126, 0.7152, 0.0722);

// Rec.2020 weights, used by AgX.
const vec3 ASTRA_LUMA_2020 = vec3(0.2627, 0.6780, 0.0593);

//==============================================================================
// ATMOSPHERE
//
// Earth-like parameters in kilometres. Minecraft has no real scale, so the
// atmosphere is modelled at planetary scale and sampled by view direction only;
// the player is treated as standing at ground level.
//==============================================================================

const float ATMO_PLANET_RADIUS     = 6360.0; // km
const float ATMO_ATMOSPHERE_RADIUS = 6460.0; // km, ~100 km shell

// Rayleigh scattering coefficients at sea level, per km, for 680/550/440 nm.
// From Bruneton & Neyret, "Precomputed Atmospheric Scattering" (2008).
const vec3 ATMO_RAYLEIGH_SCATTER = vec3(5.802e-3, 13.558e-3, 33.1e-3);
const float ATMO_RAYLEIGH_HEIGHT = 8.0; // km scale height

// Mie scattering is close to wavelength-independent for aerosol-sized particles.
const vec3 ATMO_MIE_SCATTER = vec3(3.996e-3);
const vec3 ATMO_MIE_ABSORB  = vec3(4.40e-3);
const float ATMO_MIE_HEIGHT = 1.2; // km scale height

// Henyey-Greenstein anisotropy for atmospheric aerosols.
const float ATMO_MIE_G = 0.76;

// Ozone absorbs in the Chappuis band and is what keeps twilight blue rather
// than turning it muddy brown.
const vec3 ATMO_OZONE_ABSORB = vec3(0.650e-3, 1.881e-3, 0.085e-3);
const float ATMO_OZONE_CENTER = 25.0; // km
const float ATMO_OZONE_WIDTH  = 15.0; // km half-width of the tent function

//==============================================================================
// SUN & MOON
//==============================================================================

// The sun subtends ~0.53 degrees from Earth. Stored as the cosine of the
// angular radius for cheap disc tests.
const float SUN_ANGULAR_RADIUS_RAD = 0.00465; // ~0.266 degrees, in radians

// Correlated colour temperature of direct sunlight above the atmosphere.
const float SUN_TEMPERATURE_K = 5778.0;

// Moonlight is sunlight reflected off a a dark, slightly reddish regolith, then
// perceived by scotopic vision which biases blue. The net artistic result is a
// cool tint; this is the reflectance multiplier applied to the sun colour.
const vec3 MOON_ALBEDO_TINT = vec3(0.72, 0.80, 1.00);

//==============================================================================
// WATER
//==============================================================================

// Absorption coefficients of clear water per metre, for RGB. Red is absorbed
// roughly 50x faster than blue, which is why deep water goes blue-green.
// Derived from Pope & Fry (1997) measurements, collapsed to three bands.
const vec3 WATER_ABSORPTION_COEFF = vec3(0.45, 0.075, 0.035);

// Scattering coefficient for suspended particulate. Minecraft water reads as
// fairly turbid, so this is above the value for distilled water.
const vec3 WATER_SCATTER_COEFF = vec3(0.0025, 0.0045, 0.0075);

// Index of refraction of water relative to air at 589 nm.
const float WATER_IOR = 1.333;

// F0 for a dielectric with IOR 1.333: ((n-1)/(n+1))^2
const float WATER_F0 = 0.02037;

//==============================================================================
// MATERIALS
//==============================================================================

// Default normal-incidence reflectance for common dielectrics. 0.04 corresponds
// to IOR ~1.5, which covers most non-metals well enough.
const float DIELECTRIC_F0 = 0.04;

// Roughness is clamped away from zero: a perfectly smooth GGX lobe is a delta
// function and produces fireflies under importance sampling.
const float MIN_ROUGHNESS = 0.0025;

//==============================================================================
// MATERIAL IDS
//
// Written into the gbuffer so later passes can branch on surface type without
// re-reading block data. Kept small and contiguous so they survive an 8-bit
// round trip (id / 255.0).
//==============================================================================

const int MATID_DEFAULT      = 0;
const int MATID_TERRAIN      = 1;
const int MATID_FOLIAGE      = 2;
const int MATID_WATER        = 3;
const int MATID_GLASS        = 4;
const int MATID_METAL        = 5;
const int MATID_EMISSIVE     = 6;
const int MATID_SNOW         = 7;
const int MATID_SAND         = 8;
const int MATID_ENTITY       = 9;
const int MATID_HAND         = 10;
const int MATID_PARTICLE     = 11;
const int MATID_WEATHER      = 12;
const int MATID_LAVA         = 13;
const int MATID_ICE          = 14;
const int MATID_BEACON       = 15;

//==============================================================================
// RENDERING
//==============================================================================

// Halton(2,3) sequence length used for TAA jitter. A prime-ish, non-power-of-two
// length avoids resonance with the 2x2 pixel quad.
const int TAA_JITTER_COUNT = 16;

// Blue-noise tile size in noisetex. Declared in shaders.properties as well.
const int NOISE_TEXTURE_SIZE = 256;

#endif // ASTRA_CONSTANTS_GLSL
