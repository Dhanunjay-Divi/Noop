# Strength trainer asset provenance

## NOOP human trainers

- Bundled files: `trainer-man.glb`, `trainer-woman.glb`
- Male SHA-256: `fd3e4652fa8ad8a10de284166ec38cd3a2d3b3d8bbdd463af03f237af4e0f377`
- Female SHA-256: `8aa9f8fdc6b2925d69d38b25c69f270e501cb74702ed8bcaf3ce28da46fd1262`
- Generator: `build_humans.py`
- Generated with: Blender 5.2.1 and MPFB 2.0.17
- MPFB revision: `80919fa4682335c41847f761a4d79dcad4124732`
- Source asset pack: `makehuman_system_assets_cc0.zip`
- Asset source:
  `https://files2.makehumancommunity.org/asset_packs/makehuman_system_assets/makehuman_system_assets_cc0.zip`
- Retrieved and generated: 2026-09-01
- Asset license: CC0 1.0

The meshes, targets, rig data, skin textures, clothing, hair, eyes, and shoes
used by the generator come from the MakeHuman system assets CC0 pack. The
generated characters may therefore be bundled and redistributed without the
Adobe Mixamo restrictions that applied to the previous X Bot prototype.

The deterministic Blender generator sets each phenotype, fits athletic
clothing, applies materials, builds a Mixamo-compatible skeleton, limits
textures to 1024 pixels, and exports GLB files without sample animation,
cameras, or lights. NOOP's procedural exercise poses, runtime retargeting,
equipment, viewer, and written guidance remain project-authored work.

Rebuild from a Blender installation with MPFB and the CC0 system pack enabled:

```sh
BLENDER_USER_CONFIG=/tmp/noop-blender-profile/config \
BLENDER_USER_EXTENSIONS=/tmp/noop-blender-profile/extensions \
blender -b --python build_humans.py -- /tmp/noop-human-models
```
