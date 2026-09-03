# Strength trainer asset provenance

## Exercise animation media

The native exercise viewer has one reviewed manifest for its 56 built-in
exercises. iOS, Android, the import validator, and browser QA consume identical
copies of that manifest.

The current local QA sources are:

- `Vital Animations.zip` (`Free50`): 1080 px MP4 demonstrations.
- `exercises-gifs-main.zip`: 360 px GIF demonstrations and CSV metadata.

The original `exercises-gifs-main.zip` contains an MIT `LICENSE` attributed to
`omercotkd`, and matches repository commit
`ebf642cd90fdf73a6c73e7127e93b607b12c229e`. Its README simultaneously says
the repository is a backup of a Kaggle dataset, that the maintainer does not
own the content, and that rights belong to the original creators and dataset
owner. The MIT notice therefore does not establish that the maintainer can
license the GIF copyrights. `Vital Animations.zip` contains no license or
notice entry. Both binary sets remain git-ignored and the import command
requires `--acknowledge-local-qa-only`; neither may ship until the relevant
media owner grants distribution rights.

Production builds accept separate HTTPS templates for licensed MP4 and GIF
assets. They try a 720 px or larger MP4 first, then a 360 px or larger GIF,
cache bounded downloads, and fall back to NOOP's written form guide. Five
catalog gaps are intentional and documented in `exercise-media.json`: the
supplied GIF set has no truthful plain forearm plank, bench-supported barbell
hip thrust, standard floor side plank, unanchored band pull-apart, or rowing
ergometer. Hip thrust and rowing still have exact Vital MP4s. NOOP does not
show a different movement merely to fill those fallback slots.

Debug builds may use the immutable public GitHub mirror above as a simulator
preview. Local imports go only to `build/strength-motion-media` for iOS and
Android's `src/demoDebug` assets. The production-like `fullDebug` flavor and
every release flavor therefore exclude these binaries by source-set design.
The mirror is not a release media source.

The former Blender/Three.js prototype remains available for audit on the
`archive/strength-motion-blender-v1` branch; its generator and robot/humanoid
sources are not part of `main`.

## NOOP guidance

The viewer layout, exercise-to-media mapping, and setup, movement, breathing,
tempo, and safety guidance in this directory are maintained as NOOP source.
`build-native-body-map.mjs` generates the JSON contracts consumed by both apps.
The generated `dist/viewer.js` is retained only for the 56-exercise browser QA
and is built from `viewer.ts` and `guidance.ts`.

Workout programming is also NOOP-authored. The optional Balanced, Build size,
Lean and conditioned, V-taper, Upper body, Lower body and glutes, and Athletic
performance settings prioritize exercises in the existing catalog. They are
training emphases, not promises to change skeletal body shape or fat
distribution, and are not selected from male/female body-shape classifications.
Explicit muscle choices take precedence over the broader emphasis.

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
