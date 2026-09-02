import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { PNG } from "pngjs";

const root = fileURLToPath(new URL(".", import.meta.url));
const output = resolve(process.env.NOOP_STRENGTH_QA_OUTPUT ?? "/tmp/noop-strength-motion-qa");
const manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const requestedExercises = (process.env.NOOP_STRENGTH_QA_EXERCISES ?? "")
  .split(",")
  .map((id) => id.trim())
  .filter(Boolean);
const allExercises = manifest.exercises.map(({ id }) => id);
const exercises = requestedExercises.length > 0
  ? requestedExercises.filter((id) => allExercises.includes(id))
  : allExercises;
assert(exercises.length > 0, "No matching exercises selected for QA");
const requestedBodies = (process.env.NOOP_STRENGTH_QA_BODIES ?? "")
  .split(",")
  .map((style) => style.trim())
  .filter((style) => style === "man" || style === "woman");
const bodyStyles = requestedBodies.length > 0 ? requestedBodies : ["man", "woman"];
const requestedPhases = (process.env.NOOP_STRENGTH_QA_PHASES ?? "")
  .split(",")
  .map((phase) => phase.trim())
  .filter(Boolean)
  .map(Number)
  .filter((phase) => Number.isFinite(phase) && phase >= 0 && phase <= 1);
const phases = requestedPhases.length > 0 ? requestedPhases : [0, 0.25, 0.5];
const failures = [];
const staticPhaseExercises = new Set(["plank", "side_plank"]);

await mkdir(output, { recursive: true });
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    if (url.pathname === "/favicon.ico") {
      response.statusCode = 204;
      response.end();
      return;
    }
    const relative = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const file = relative === "viewer.js"
      ? join(root, "dist", "viewer.js")
      : join(root, relative);
    if (!file.startsWith(root)) throw new Error("Invalid path");
    response.setHeader("Content-Type", mimeType(file));
    response.end(await readFile(file));
  } catch {
    response.statusCode = 404;
    response.end("Not found");
  }
});
await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
const address = server.address();
assert(address && typeof address === "object");
const baseURL = `http://127.0.0.1:${address.port}`;

const browser = await chromium.launch({ channel: "chrome", headless: true });
const context = await browser.newContext({
  viewport: { width: 560, height: 346 },
  colorScheme: "dark",
  deviceScaleFactor: 1,
});
const page = await context.newPage();
page.on("pageerror", (error) => failures.push(`browser: ${error.message}`));
page.on("console", (message) => {
  if (message.type() === "error") failures.push(`console: ${message.text()}`);
});

const images = [];
const totalRenders = exercises.length * bodyStyles.length * phases.length;
let rendered = 0;
for (const bodyStyle of bodyStyles) {
  for (const phase of phases) {
    for (const [index, id] of exercises.entries()) {
      const label = `${bodyStyle}/${phaseLabel(phase)}/${id}`;
      try {
        await page.goto(
          `${baseURL}/index.html?exercise=${id}&reduceMotion=1&phase=${phase}&body=${bodyStyle}`,
        );
        await page.locator("body[data-ready='true']").waitFor({ state: "attached" });
        await assertViewerState(page, id, bodyStyle);
        const image = await page.locator("#stage").screenshot();
        assertVisibleHuman(image, label);
        const filename =
          `${bodyStyle}-${phaseLabel(phase)}-${String(index).padStart(2, "0")}-${id}.png`;
        await writeFile(join(output, filename), image);
        images.push({ id, bodyStyle, phase, filename, image });
        rendered += 1;
        process.stdout.write(
          `rendered ${String(rendered).padStart(3, "0")}/${totalRenders} ${label}\n`,
        );
      } catch (error) {
        failures.push(`${label}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
}

verifyBodyStyleDifferences(images, exercises, bodyStyles, phases, failures);
verifyPhaseMotion(images, exercises, bodyStyles, phases, failures);

try {
  await verifyInteractions(page);
} catch (error) {
  failures.push(`interactions: ${error instanceof Error ? error.message : String(error)}`);
}

const contactSheets = await writeContactSheets(page, images, bodyStyles, phases);
await context.close();
await browser.close();
await new Promise((resolvePromise, reject) =>
  server.close((error) => error ? reject(error) : resolvePromise()),
);

const report = {
  generatedAt: new Date().toISOString(),
  exerciseCount: exercises.length,
  bodyStyles,
  phases,
  expectedRenderCount: totalRenders,
  renderedCount: images.length,
  contactSheets,
  failures,
};
await writeFile(join(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log(`QA passed: ${images.length} renders across ${exercises.length} exercises`);
  console.log(`Contact sheets: ${contactSheets.map((file) => join(output, file)).join(", ")}`);
}

async function assertViewerState(currentPage, id, bodyStyle) {
  const state = await currentPage.evaluate(() => ({
    ready: document.body.dataset.ready,
    model: document.body.dataset.model,
    bodyStyle: document.body.dataset.bodyStyle,
    error: document.body.dataset.error,
    loadingHidden: document.querySelector("#loading")?.hidden,
    errorHidden: document.querySelector("#error")?.hidden,
    title: document.querySelector("#instruction-title")?.textContent?.trim() ?? "",
    setup: document.querySelector("#instruction-setup")?.textContent?.trim() ?? "",
    movement: document.querySelector("#instruction-movement")?.textContent?.trim() ?? "",
    breathing: document.querySelector("#instruction-breathing")?.textContent?.trim() ?? "",
    tempo: document.querySelector("#instruction-tempo")?.textContent?.trim() ?? "",
    safety: document.querySelector("#instruction-safety")?.textContent?.trim() ?? "",
  }));
  assert.equal(state.ready, "true", `${id} did not reach ready state`);
  assert.equal(state.model, "humanoid", `${id} did not load the skinned human model`);
  assert.equal(state.bodyStyle, bodyStyle, `${id} loaded the wrong body style`);
  assert.equal(state.error, undefined, `${id} entered error state`);
  assert.equal(state.loadingHidden, true, `${id} left loading visible`);
  assert.equal(state.errorHidden, true, `${id} left error visible`);
  assert(state.title.length >= 3, `${id} has no title`);
  for (const field of ["setup", "movement", "breathing", "tempo", "safety"]) {
    assert(state[field].length >= 24, `${id} has incomplete ${field} guidance`);
  }
}

function assertVisibleHuman(buffer, label) {
  const png = PNG.sync.read(buffer);
  let humanPixels = 0;
  let edgeHumanPixels = 0;
  for (let y = 0; y < png.height; y += 1) {
    for (let x = 0; x < png.width; x += 1) {
      const offset = (y * png.width + x) * 4;
      const red = png.data[offset];
      const green = png.data[offset + 1];
      const blue = png.data[offset + 2];
      const isBlueClothing =
        blue > 55 && blue > red * 1.25 && blue > green * 1.05;
      const isSkin =
        red > 58 &&
        green > 24 &&
        blue > 12 &&
        red > green * 1.15 &&
        green > blue * 1.05;
      if (!isBlueClothing && !isSkin) continue;
      humanPixels += 1;
      if (x < 3 || x >= png.width - 3 || y < 3 || y >= png.height - 3) {
        edgeHumanPixels += 1;
      }
    }
  }
  assert(humanPixels > 350, `${label} rendered too few human pixels (${humanPixels})`);
  assert(
    edgeHumanPixels < 20,
    `${label} human is clipped (${edgeHumanPixels} edge pixels)`,
  );
}

function verifyBodyStyleDifferences(entries, ids, styles, checkedPhases, errors) {
  if (!styles.includes("man") || !styles.includes("woman")) return;
  for (const id of ids) {
    for (const phase of checkedPhases) {
      const man = findImage(entries, id, "man", phase);
      const woman = findImage(entries, id, "woman", phase);
      if (!man || !woman) continue;
      const difference = pixelDifference(man.image, woman.image);
      if (difference < 0.012) {
        errors.push(
          `${id}/${phaseLabel(phase)}: body styles are not visually distinct (${difference})`,
        );
      }
    }
  }
}

function verifyPhaseMotion(entries, ids, styles, checkedPhases, errors) {
  if (checkedPhases.length < 2) return;
  for (const id of ids) {
    if (staticPhaseExercises.has(id)) continue;
    for (const style of styles) {
      const sequence = checkedPhases
        .map((phase) => findImage(entries, id, style, phase))
        .filter(Boolean);
      if (sequence.length < 2) continue;
      let largestDifference = 0;
      for (let index = 1; index < sequence.length; index += 1) {
        largestDifference = Math.max(
          largestDifference,
          pixelDifference(sequence[0].image, sequence[index].image),
        );
      }
      if (largestDifference < 0.004) {
        errors.push(`${style}/${id}: phases do not produce visible motion`);
      }
    }
  }
}

function findImage(entries, id, bodyStyle, phase) {
  return entries.find(
    (entry) =>
      entry.id === id &&
      entry.bodyStyle === bodyStyle &&
      Math.abs(entry.phase - phase) < 0.000001,
  );
}

async function verifyInteractions(currentPage) {
  await currentPage.goto(
    `${baseURL}/index.html?exercise=barbell_back_squat&reduceMotion=1&phase=0.62&body=man`,
  );
  await currentPage.locator("body[data-ready='true']").waitFor({ state: "attached" });
  const stage = currentPage.locator("#stage");
  const initial = await stage.screenshot();
  const box = await stage.boundingBox();
  assert(box);

  await currentPage.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.5);
  await currentPage.mouse.down();
  await currentPage.mouse.move(box.x + box.width * 0.68, box.y + box.height * 0.46, { steps: 12 });
  await currentPage.mouse.up();
  await currentPage.waitForTimeout(350);
  const rotated = await stage.screenshot();
  assert.notEqual(digest(initial), digest(rotated), "drag did not rotate the model");

  await currentPage.mouse.wheel(0, -420);
  await currentPage.waitForTimeout(350);
  const zoomed = await stage.screenshot();
  assert.notEqual(digest(rotated), digest(zoomed), "wheel did not zoom the model");

  await currentPage.locator("#reset").click();
  await currentPage.waitForTimeout(700);
  const reset = await stage.screenshot();
  assert(pixelDifference(initial, reset) < 0.015, "reset did not restore the camera");

  await currentPage.locator("#info").click();
  await assertVisible(currentPage.locator("#instructions"));
  assert.match(await currentPage.locator("#instruction-title").innerText(), /Squat/);
  await currentPage.locator("#close").click();
  await assertHidden(currentPage.locator("#instructions"));

  const manImage = await stage.screenshot();
  await currentPage.locator("[data-body-style='woman']").click();
  await currentPage.locator("body[data-body-style='woman']").waitFor({ state: "attached" });
  await currentPage.waitForTimeout(250);
  const womanImage = await stage.screenshot();
  assert(
    pixelDifference(manImage, womanImage) > 0.012,
    "body-style selector did not visibly change the trainer",
  );
  await currentPage.locator("[data-body-style='man']").click();
  await currentPage.locator("body[data-body-style='man']").waitFor({ state: "attached" });

  await currentPage.goto(
    `${baseURL}/index.html?exercise=barbell_back_squat&reduceMotion=0&duration=3.2&body=man`,
  );
  await currentPage.locator("body[data-ready='true']").waitFor({ state: "attached" });
  const pause = currentPage.locator("#pause");
  assert.equal(await pause.getAttribute("aria-label"), "Pause animation");
  await pause.click();
  assert.equal(await pause.getAttribute("aria-label"), "Play animation");
  const pausedOne = await currentPage.locator("#stage").screenshot();
  await currentPage.waitForTimeout(350);
  const pausedTwo = await currentPage.locator("#stage").screenshot();
  assert(pixelDifference(pausedOne, pausedTwo) < 0.003, "pause did not freeze the model");
}

async function writeContactSheets(currentPage, entries, styles, checkedPhases) {
  await currentPage.setViewportSize({ width: 1600, height: 900 });
  const files = [];
  for (const style of styles) {
    for (const phase of checkedPhases) {
      const group = entries.filter(
        (entry) =>
          entry.bodyStyle === style && Math.abs(entry.phase - phase) < 0.000001,
      );
      if (group.length === 0) continue;
      const cards = group.map(({ id, image }, index) => `
        <figure>
          <img src="data:image/png;base64,${image.toString("base64")}" alt="">
          <figcaption><b>${String(index + 1).padStart(2, "0")}</b> ${escapeHTML(id)}</figcaption>
        </figure>
      `).join("");
      await currentPage.setContent(`<!doctype html>
        <style>
          * { box-sizing: border-box; }
          body { margin: 0; padding: 16px; background: #08090c; color: #f5f5f6;
            font: 12px -apple-system, BlinkMacSystemFont, sans-serif; }
          main { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
          figure { margin: 0; border: 1px solid #30333a; background: #111318; }
          img { display: block; width: 100%; aspect-ratio: 1.62; object-fit: cover; }
          figcaption { padding: 8px 10px; overflow-wrap: anywhere; }
          b { color: #ed3442; margin-right: 5px; }
        </style><main>${cards}</main>`);
      const file = `contact-sheet-${style}-${phaseLabel(phase)}.png`;
      await currentPage.screenshot({ path: join(output, file), fullPage: true });
      files.push(file);
    }
  }
  return files;
}

async function assertVisible(locator) {
  assert.equal(await locator.getAttribute("hidden"), null);
}

async function assertHidden(locator) {
  assert.notEqual(await locator.getAttribute("hidden"), null);
}

function digest(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function phaseLabel(phase) {
  return `p${String(Math.round(phase * 100)).padStart(3, "0")}`;
}

function pixelDifference(first, second) {
  const a = PNG.sync.read(first);
  const b = PNG.sync.read(second);
  assert.equal(a.width, b.width);
  assert.equal(a.height, b.height);
  let changed = 0;
  const pixels = a.width * a.height;
  for (let index = 0; index < a.data.length; index += 4) {
    const distance =
      Math.abs(a.data[index] - b.data[index]) +
      Math.abs(a.data[index + 1] - b.data[index + 1]) +
      Math.abs(a.data[index + 2] - b.data[index + 2]);
    if (distance > 18) changed += 1;
  }
  return changed / pixels;
}

function mimeType(file) {
  switch (extname(file)) {
    case ".html": return "text/html; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    case ".json": return "application/json; charset=utf-8";
    default: return "application/octet-stream";
  }
}

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character]);
}
