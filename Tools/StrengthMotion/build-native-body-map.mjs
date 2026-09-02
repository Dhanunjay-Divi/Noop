import { copyFile, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const source = await readFile(new URL("body-paths.ts", import.meta.url), "utf8");
const viewerSource = await readFile(new URL("viewer.ts", import.meta.url), "utf8");
const manifest = JSON.parse(
  await readFile(new URL("manifest.json", import.meta.url), "utf8"),
);
const { exerciseInstructions } = await import(
  `${new URL("dist/guidance.js", import.meta.url).href}?build=${Date.now()}`
);
const match = source.match(/export default (\{[\s\S]*\});?\s*$/);
if (!match) throw new Error("Could not extract MuscleMap geometry");

const geometry = JSON.parse(match[1]).male;
const muscleByGeometry = {
  chest: "chest",
  trapezius: "back",
  "upper-back": "back",
  "lower-back": "back",
  serratus: "back",
  deltoids: "shoulders",
  biceps: "biceps",
  triceps: "triceps",
  forearm: "forearms",
  abs: "core",
  obliques: "core",
  quadriceps: "quadriceps",
  hamstring: "hamstrings",
  gluteal: "glutes",
  adductors: "glutes",
  "hip-flexors": "quadriceps",
  calves: "calves",
  tibialis: "calves",
};
const inert = new Set(["head", "hair", "neck", "hands", "feet", "knees", "ankles"]);

const groups = ["front", "back"].map((side) => {
  const paths = Object.entries(geometry[side].p).flatMap(([part, values]) => {
    const muscle = muscleByGeometry[part];
    const fill = !muscle || inert.has(part)
      ? "#34373f"
      : `__NOOP_${muscle.toUpperCase()}__`;
    return values.map((path) =>
      `    <path fill="${fill}" stroke="#08090c" stroke-width="2" ` +
      `stroke-linejoin="round" d="${path}"/>`
    );
  });
  return `  <g id="${side}">\n${paths.join("\n")}\n  </g>`;
});

const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg"
     viewBox="0 75 1517 1300"
     preserveAspectRatio="xMidYMid meet">
${groups.join("\n")}
</svg>
`;

const toolOutput = new URL("body-map-native.svg", import.meta.url);
const androidOutput = new URL(
  "../../android/app/src/main/assets/strength-motion/body-map-native.svg",
  import.meta.url,
);
const mappingBlock = viewerSource.match(
  /const mediaIds:[\s\S]*?= \{([\s\S]*?)\n\};/,
)?.[1] ?? "";
const mediaIds = Object.fromEntries(
  [...mappingBlock.matchAll(/^\s{2}([a-z0-9_]+): "([A-Za-z0-9]+)",$/gm)]
    .map((entry) => [entry[1], entry[2]]),
);
if (Object.keys(mediaIds).length !== 56) {
  throw new Error(`Expected 56 exercise media mappings, found ${Object.keys(mediaIds).length}`);
}
const mediaMap = `${JSON.stringify(mediaIds, null, 2)}\n`;
const toolMediaOutput = new URL("exercise-media.json", import.meta.url);
const androidMediaOutput = new URL(
  "../../android/app/src/main/assets/strength-motion/exercise-media.json",
  import.meta.url,
);
const appleMediaOutput = new URL(
  "../../Strand/Resources/StrengthMotion/exercise-media.json",
  import.meta.url,
);
const exerciseGuidance = Object.fromEntries(
  manifest.exercises.map(({ id }) => [id, exerciseInstructions(id)]),
);
if (Object.keys(exerciseGuidance).length !== 56) {
  throw new Error(
    `Expected 56 exercise guidance records, found ${Object.keys(exerciseGuidance).length}`,
  );
}
const guidanceJSON = `${JSON.stringify(exerciseGuidance, null, 2)}\n`;
const toolGuidanceOutput = new URL("exercise-guidance.json", import.meta.url);
const androidGuidanceOutput = new URL(
  "../../android/app/src/main/assets/strength-motion/exercise-guidance.json",
  import.meta.url,
);
const appleGuidanceOutput = new URL(
  "../../Strand/Resources/StrengthMotion/exercise-guidance.json",
  import.meta.url,
);
const appleBodyMapDirectory = new URL(
  "../../Strand/Resources/StrengthMotion/",
  import.meta.url,
);
await Promise.all([
  writeFile(toolOutput, svg),
  writeFile(androidOutput, svg),
  writeFile(toolMediaOutput, mediaMap),
  writeFile(androidMediaOutput, mediaMap),
  writeFile(appleMediaOutput, mediaMap),
  writeFile(toolGuidanceOutput, guidanceJSON),
  writeFile(androidGuidanceOutput, guidanceJSON),
  writeFile(appleGuidanceOutput, guidanceJSON),
  copyFile(
    new URL("dist/body-map.js", import.meta.url),
    new URL("body-map.js", appleBodyMapDirectory),
  ),
  copyFile(
    new URL("body-map.html", import.meta.url),
    new URL("body-map.html", appleBodyMapDirectory),
  ),
  copyFile(
    new URL("body-map.css", import.meta.url),
    new URL("body-map.css", appleBodyMapDirectory),
  ),
]);
console.log(`Generated native Strength assets from ${root}`);
