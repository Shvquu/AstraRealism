#ifndef ASTRA_COMMON_GLSL
#define ASTRA_COMMON_GLSL

/*
 * AstraRealism - Umbrella include.
 *
 * Every program includes this and nothing else from lib/common. The include
 * order matters: settings defines the options, compat resolves them against
 * hardware capability, and the rest build on both.
 */

#include "/lib/common/settings.glsl"
#include "/lib/compat/version.glsl"
#include "/lib/compat/fallback.glsl"

#include "/lib/common/constants.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/buffers.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/spaces.glsl"

// Needed by both ends of the pipeline: the gbuffers vertex stage applies the
// TAA jitter and the resolve pass removes it.
#include "/lib/post/jitter.glsl"

// Shared by every temporally accumulated system: GI, volumetrics, clouds.
#include "/lib/common/temporal.glsl"

#endif // ASTRA_COMMON_GLSL
