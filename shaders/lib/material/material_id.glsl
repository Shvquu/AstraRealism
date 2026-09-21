#ifndef ASTRA_MATERIAL_ID_GLSL
#define ASTRA_MATERIAL_ID_GLSL

#include "/lib/common/constants.glsl"

/*
 * AstraRealism - Block classification.
 *
 * Turns the integer ids declared in shaders/block.properties into the MATID_*
 * constants the rest of the pack uses, and provides the per-class material
 * defaults used when no LabPBR resource pack is present.
 *
 * The ASTRA_BLOCK_* values below MUST match the block.<n> entries in
 * block.properties. tools/validate_shader.py verifies that.
 */

//==============================================================================
// BLOCK PROPERTY IDS
//==============================================================================

const int ASTRA_BLOCK_NONE      = 0;
const int ASTRA_BLOCK_FOLIAGE   = 1;
const int ASTRA_BLOCK_PLANT     = 2;
const int ASTRA_BLOCK_WATER     = 3;
const int ASTRA_BLOCK_GLASS     = 4;
const int ASTRA_BLOCK_EMISSIVE  = 5;
const int ASTRA_BLOCK_LAVA      = 6;
const int ASTRA_BLOCK_SNOW      = 7;
const int ASTRA_BLOCK_SAND      = 8;
const int ASTRA_BLOCK_METAL     = 9;
const int ASTRA_BLOCK_ICE       = 10;
const int ASTRA_BLOCK_POROUS    = 11;

//==============================================================================
// CLASSIFICATION
//==============================================================================

/*
 * Map a block.properties id to a material id.
 *
 * The program macro takes priority over the block id: geometry drawn by
 * gbuffers_entities is an entity regardless of what block it resembles, and
 * the hand must be distinguishable because it does not move with the world and
 * so must be excluded from temporal reprojection.
 */
int classifyMaterial(int blockId) {
#if defined(PROGRAM_HAND)
    return MATID_HAND;
#elif defined(PROGRAM_ENTITIES)
    return MATID_ENTITY;
#elif defined(PROGRAM_WEATHER)
    return MATID_WEATHER;
#elif defined(PROGRAM_BEACONBEAM)
    return MATID_BEACON;
#elif defined(PROGRAM_TEXTURED) || defined(PROGRAM_TEXTURED_LIT)
    return MATID_PARTICLE;
#else
    // Foliage and small plants share a material response; they differ only in
    // how the wind animation anchors them, which the vertex stage handles.
    if (blockId == ASTRA_BLOCK_FOLIAGE || blockId == ASTRA_BLOCK_PLANT) return MATID_FOLIAGE;
    if (blockId == ASTRA_BLOCK_WATER)    return MATID_WATER;
    if (blockId == ASTRA_BLOCK_GLASS)    return MATID_GLASS;
    if (blockId == ASTRA_BLOCK_EMISSIVE) return MATID_EMISSIVE;
    if (blockId == ASTRA_BLOCK_LAVA)     return MATID_LAVA;
    if (blockId == ASTRA_BLOCK_SNOW)     return MATID_SNOW;
    if (blockId == ASTRA_BLOCK_SAND)     return MATID_SAND;
    if (blockId == ASTRA_BLOCK_METAL)    return MATID_METAL;
    if (blockId == ASTRA_BLOCK_ICE)      return MATID_ICE;

    // Porous stone is ordinary terrain that happens to darken more in rain.
    // The distinction only matters to the wetness model.
    if (blockId == ASTRA_BLOCK_POROUS)   return MATID_TERRAIN;

    #if defined(PROGRAM_WATER)
        // Translucent geometry with no block id: stained glass panes from mods,
        // or blocks the properties file does not cover. Glass is the safer
        // assumption than water because it does not trigger wave displacement.
        return MATID_GLASS;
    #elif defined(PROGRAM_TERRAIN) || defined(PROGRAM_BLOCK)
        return MATID_TERRAIN;
    #else
        return MATID_DEFAULT;
    #endif
#endif
}

//==============================================================================
// MATERIAL CLASS QUERIES
//
// Used throughout the lighting code so call sites read as intent rather than
// as a list of magic comparisons.
//==============================================================================

bool materialIsTranslucent(int id) {
    return id == MATID_WATER || id == MATID_GLASS || id == MATID_ICE;
}

bool materialIsFoliage(int id) {
    return id == MATID_FOLIAGE;
}

// Materials that transmit light through thin geometry when backlit.
bool materialHasSubsurface(int id) {
    return id == MATID_FOLIAGE || id == MATID_SNOW || id == MATID_ICE;
}

// Materials that should never be darkened or glossed by rain.
bool materialIgnoresWetness(int id) {
    return id == MATID_WATER || id == MATID_LAVA || id == MATID_GLASS
        || id == MATID_ICE   || id == MATID_EMISSIVE
        || id == MATID_HAND  || id == MATID_WEATHER || id == MATID_PARTICLE;
}

bool materialIsEmissive(int id) {
    return id == MATID_EMISSIVE || id == MATID_LAVA || id == MATID_BEACON;
}

// Geometry that does not move with the world, and so must not receive the
// camera-delta term during temporal reprojection.
bool materialIsScreenAnchored(int id) {
    return id == MATID_HAND;
}

//==============================================================================
// FALLBACK MATERIAL DEFAULTS
//
// Used when no LabPBR resource pack is available. These are plausible values
// for each class rather than measured ones - the point is that a stone wall
// and a sheet of ice stop responding to light identically, not that either
// matches a spectrophotometer.
//==============================================================================

struct MaterialDefaults {
    float roughness;
    float f0;
    float emissive;
    float porosity;
};

MaterialDefaults defaultsForMaterial(int id) {
    MaterialDefaults m;

    // Sensible dielectric baseline; each case below overrides what differs.
    m.roughness = 0.85;
    m.f0 = DIELECTRIC_F0;
    m.emissive = 0.0;
    m.porosity = 0.25;

    if (id == MATID_METAL) {
        // 230/255 is the lowest value LabPBR treats as metallic.
        m.roughness = 0.35;
        m.f0 = 230.0 / 255.0;
        m.porosity = 0.0;
    } else if (id == MATID_WATER) {
        m.roughness = 0.02;
        m.f0 = WATER_F0;
        m.porosity = 0.0;
    } else if (id == MATID_ICE) {
        m.roughness = 0.12;
        m.f0 = 0.018;
        m.porosity = 0.0;
    } else if (id == MATID_GLASS) {
        m.roughness = 0.05;
        m.f0 = DIELECTRIC_F0;
        m.porosity = 0.0;
    } else if (id == MATID_SNOW) {
        // Snow is rough at the micro scale but its packed surface has a faint
        // sheen, and it scatters strongly - hence the high porosity, which
        // doubles as subsurface strength.
        m.roughness = 0.62;
        m.porosity = 0.90;
    } else if (id == MATID_FOLIAGE) {
        // Leaves have a waxy cuticle, so they are glossier than they look.
        m.roughness = 0.55;
        m.porosity = 0.85;
    } else if (id == MATID_SAND) {
        m.roughness = 0.95;
        m.porosity = 0.60;
    } else if (id == MATID_LAVA) {
        m.roughness = 0.75;
        m.emissive = 1.0;
        m.porosity = 0.0;
    } else if (id == MATID_EMISSIVE) {
        m.emissive = 1.0;
        m.roughness = 0.60;
    } else if (id == MATID_BEACON) {
        m.emissive = 1.0;
        m.roughness = 0.10;
    } else if (id == MATID_ENTITY) {
        m.roughness = 0.70;
        m.porosity = 0.40;
    }

    return m;
}

#endif // ASTRA_MATERIAL_ID_GLSL
