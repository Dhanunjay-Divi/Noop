# Strength trainer asset provenance

## Exercise animation media

NOOP's built-in exercise viewer maps its own exercise identifiers to ExerciseDB
media identifiers and loads each animation at runtime from:

`https://static.exercisedb.dev/media/<media-id>.gif`

The media is attributed in the form guide to AscendAPI. It is not stored in
this repository or distributed in the iOS or Android application bundles.
Android loads and caches it with Coil; Apple platforms use URLSession's HTTP
cache and native image views. Both implementations construct URLs only from
the generated local identifier map and the exact HTTPS host above.

ExerciseDB media remains third-party content subject to its provider's terms:

- https://exercisedb.io/faq
- https://ascendapi.com

The supplied OpenGym archives also reference this media, but their notice says
that OpenGym cannot sublicense or redistribute it. NOOP therefore does not copy
the animation files from those archives.

The former Blender/Three.js prototype remains available for audit on the
`archive/strength-motion-blender-v1` branch; its generator and robot/humanoid
sources are not part of `main`.

## NOOP guidance

The viewer layout, exercise-to-media mapping, and setup, movement, breathing,
tempo, and safety guidance in this directory are maintained as NOOP source.
`build-native-body-map.mjs` generates the JSON contracts consumed by both apps.
The generated `dist/viewer.js` is retained only for the 56-exercise browser QA
and is built from `viewer.ts` and `guidance.ts`.

## Anatomical body map

`body-paths.ts` contains SVG path geometry derived from MuscleMap by Melih
Colpan and converted from its Swift path source by openGym. MuscleMap is
licensed under MIT. The conversion is identified as MIT-licensed body geometry
in openGym's `NOTICE.md`; NOOP does not copy openGym's AGPL React component,
styling, load calculations, or interaction code. The exact MuscleMap notice is
preserved at `ThirdPartyNotices/licenses/assets/musclemap.txt` and included in
each generated release `NOTICE`.

- MuscleMap: https://github.com/melihcolpan/MuscleMap
- Conversion source reviewed: the user-supplied `opengym_2.zip`, commit
  `75fb168a03de09f995d05efd4fd2bfda2d595e0f`
- Imported: 2026-09-02

NOOP's `body-map.ts`, native platform bridges, score mapping, colors, and
accessibility behavior are project-authored work.
