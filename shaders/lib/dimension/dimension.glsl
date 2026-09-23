#ifndef ASTRA_DIMENSION_GLSL
#define ASTRA_DIMENSION_GLSL

#include "/lib/common/common.glsl"

/*
 * AstraRealism - Dimension dispatch.
 *
 * The DIM_OVERWORLD / DIM_NETHER / DIM_END macros have been set by every
 * generated program stub since Phase 0, but nothing read them until now. This
 * file is where they finally branch.
 *
 * Each dimension supplies the same four functions, so the rest of the pack
 * calls them without knowing which world it is in:
 *
 *   dimensionHasSky()        is there an atmosphere to scatter light?
 *   dimensionHasClouds()     should the cloud pass run at all?
 *   dimensionSkyRadiance()   what a view ray returns when it hits no geometry
 *   dimensionAmbientLight()  irradiance on a surface, already gated however
 *                            that dimension requires
 *   dimensionFogColor()      what distant geometry fades into
 *   dimensionFogExtinction() how quickly it fades

 * Note that ambient gating belongs to the dimension rather than the caller.
 * The overworld gates on the sky lightmap, because there ambient light IS
 * skylight. The Nether and the End cannot: Minecraft reports zero sky light
 * throughout both, so gating on it would render them entirely black.
 *
 * The Nether and the End are not tinted overworlds. Neither has a sun, so
 * neither has directional shadows or atmospheric scattering in the ordinary
 * sense; what light exists is ambient and local. Building them by recolouring
 * the overworld model is exactly what the specification rules out.
 */

#if defined(DIM_NETHER)
    #include "/lib/dimension/nether.glsl"
#elif defined(DIM_END)
    #include "/lib/dimension/end.glsl"
#else
    #include "/lib/dimension/overworld.glsl"
#endif

#endif // ASTRA_DIMENSION_GLSL
