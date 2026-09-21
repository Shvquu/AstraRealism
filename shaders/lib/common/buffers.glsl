#ifndef ASTRA_BUFFERS_GLSL
#define ASTRA_BUFFERS_GLSL

/*
 * AstraRealism - Render target configuration.
 *
 * Iris scans the preprocessed source of the shader programs for these const
 * declarations, so this file must be included by the programs. It is pulled in
 * through /lib/common/common.glsl, which every program includes.
 *
 * Layout
 * ------
 *   0   RGBA16F  scene HDR radiance                              clear
 *   1   RGBA16   gbuffer A: albedo.rgb | materialId              clear
 *   2   RGBA16   gbuffer B: normal.xy  | geoNormal.xy            clear
 *   3   RGBA8    gbuffer C: rough | f0 | emissive | porosity     clear
 *   4   RGBA16F  gbuffer D: blockLight | skyLight | ao | wetness clear
 *   5   RGBA16F  TAA colour history                              KEEP
 *   6   RGBA16F  GI irradiance accumulation                      KEEP
 *   7   RGBA16F  GI first/second moments + history length        KEEP
 *   8   RGBA16F  SSR accumulation                                KEEP
 *   9   RGBA16F  volumetric scattering.rgb + transmittance.a     clear
 *   10  RGBA16F  volumetric clouds, temporally reprojected       KEEP
 *   11  RGBA16F  bloom mip chain                                 clear
 *   12  RGBA16F  bloom / DOF scratch                             clear
 *   13  RGBA32F  previous-frame linear depth + motion vectors    KEEP
 *   14  RGBA16F  atmosphere LUTs (transmittance / sky view)      KEEP
 *   15  RGBA32F  exposure state and luminance histogram          KEEP
 *
 * "KEEP" buffers use clear=false. That is the mechanism every temporal system
 * in this pack relies on: the buffer survives into the next frame so the
 * shader can read its own previous output.
 *
 * Precision notes
 * ---------------
 * colortex1/2 are RGBA16 (unsigned normalised), not RGBA8. Octahedral normals
 * at 8 bits produce visible banding in smooth specular highlights, and 8-bit
 * albedo loses detail once auto-exposure stretches dark scenes.
 *
 * colortex13/15 are RGBA32F because both store values where a 10-bit mantissa
 * is not enough: linear depth used for disocclusion tests, and an exposure
 * value that is integrated across hundreds of frames.
 */

//==============================================================================
// FORMATS
//
// These MUST stay inside a block comment, one declaration per line.
//
// Format names such as RGBA16F are not GLSL identifiers - they exist only in
// Iris's directive vocabulary. Iris scans the raw source for these directives
// and applies them, while the GLSL compiler never sees them. Written as real
// code they produce "undeclared identifier: RGBA16F" and the pack fails to
// load.
//==============================================================================

/*
const int colortex0Format  = RGBA16F;
const int colortex1Format  = RGBA16;
const int colortex2Format  = RGBA16;
const int colortex3Format  = RGBA8;
const int colortex4Format  = RGBA16F;
const int colortex5Format  = RGBA16F;
const int colortex6Format  = RGBA16F;
const int colortex7Format  = RGBA16F;
const int colortex8Format  = RGBA16F;
const int colortex9Format  = RGBA16F;
const int colortex10Format = RGBA16F;
const int colortex11Format = RGBA16F;
const int colortex12Format = RGBA16F;
const int colortex13Format = RGBA32F;
const int colortex14Format = RGBA16F;
const int colortex15Format = RGBA32F;
*/

//==============================================================================
// CLEARING
//
// Kept in a block comment alongside the formats for consistency. Unlike the
// formats these are valid GLSL, but nothing in the pack reads them - they are
// purely instructions to Iris.
//==============================================================================

/*
const bool colortex5Clear  = false;
const bool colortex6Clear  = false;
const bool colortex7Clear  = false;
const bool colortex8Clear  = false;
const bool colortex10Clear = false;
const bool colortex13Clear = false;
const bool colortex14Clear = false;
const bool colortex15Clear = false;
*/

//==============================================================================
// SHADOW MAP
//==============================================================================

/*
 * Hardware depth comparison gives free 2x2 PCF on the sampler. We do our own
 * filtering, so it is disabled: mixing hardware comparison with a manual PCSS
 * blocker search returns pre-filtered occlusion values where raw depth is
 * needed, which breaks the penumbra estimate.
 */
const bool shadowHardwareFiltering = false;

// shadowtex1 excludes translucent casters. Comparing it against shadowtex0 is
// how coloured shadows are detected.
const bool shadowtex0Nearest = true;
const bool shadowtex1Nearest = true;
const bool shadowcolor0Nearest = false;

// Translucent casters must write colour, so the shadow colour buffer is cleared
// to white (fully transmissive) rather than black.
const vec4 shadowcolor0ClearColor = vec4(1.0, 1.0, 1.0, 1.0);

//==============================================================================
// NOISE TEXTURE
//==============================================================================

const int noiseTextureResolution = 256;

#endif // ASTRA_BUFFERS_GLSL
