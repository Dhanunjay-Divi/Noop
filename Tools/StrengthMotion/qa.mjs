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
const failures = [];

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
for (const [index, id] of exercises.entries()) {
  try {
    await page.goto(`${baseURL}/index.html?exercise=${id}&reduceMotion=1&phase=0.62`);
    await page.locator("body[data-ready='true']").waitFor({ state: "attached" });
    await assertViewerState(page, id);
    const image = await page.locator("#stage").screenshot();
    assertVisibleModel(image, id);
    const filename = `${String(index).padStart(2, "0")}-${id}.png`;
    await writeFile(join(output, filename), image);
    images.push({ id, filename, image });
    process.stdout.write(`rendered ${String(index + 1).padStart(2, "0")}/${exercises.length} ${id}\n`);
  } catch (error) {
    failures.push(`${id}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

try {
  await verifyInteractions(page);
} catch (error) {
  failures.push(`interactions: ${error instanceof Error ? error.message : String(error)}`);
}

await writeContactSheet(page, images);
await context.close();
await browser.close();
await new Promise((resolvePromise, reject) =>
  server.close((error) => error ? reject(error) : resolvePromise()),
);

const report = {
  generatedAt: new Date().toISOString(),
  exerciseCount: exercises.length,
  renderedCount: images.length,
  failures,
};
await writeFile(join(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log(`QA passed: ${images.length} exercises`);
  console.log(`Contact sheet: ${join(output, "contact-sheet.png")}`);
}

async function assertViewerState(currentPage, id) {
  const state = await currentPage.evaluate(() => ({
    ready: document.body.dataset.ready,
    model: document.body.dataset.model,
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
  assert.equal(state.error, undefined, `${id} entered error state`);
  assert.equal(state.loadingHidden, true, `${id} left loading visible`);
  assert.equal(state.errorHidden, true, `${id} left error visible`);
  assert(state.title.length >= 3, `${id} has no title`);
  for (const field of ["setup", "movement", "breathing", "tempo", "safety"]) {
    assert(state[field].length >= 24, `${id} has incomplete ${field} guidance`);
  }
}

function assertVisibleModel(buffer, id) {
  const png = PNG.sync.read(buffer);
  let redPixels = 0;
  let edgeRedPixels = 0;
  for (let y = 0; y < png.height; y += 1) {
    for (let x = 0; x < png.width; x += 1) {
      const offset = (y * png.width + x) * 4;
      const red = png.data[offset];
      const green = png.data[offset + 1];
      const blue = png.data[offset + 2];
      const isModelRed = red > 75 && red > green * 1.45 && red > blue * 1.2;
      if (!isModelRed) continue;
      redPixels += 1;
      if (x < 3 || x >= png.width - 3 || y < 3 || y >= png.height - 3) {
        edgeRedPixels += 1;
      }
    }
  }
  assert(redPixels > 600, `${id} rendered too few model pixels (${redPixels})`);
  assert(edgeRedPixels < 8, `${id} model is clipped (${edgeRedPixels} edge pixels)`);
}

async function verifyInteractions(currentPage) {
  await currentPage.goto(
    `${baseURL}/index.html?exercise=barbell_back_squat&reduceMotion=1&phase=0.62`,
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

  await currentPage.goto(
    `${baseURL}/index.html?exercise=barbell_back_squat&reduceMotion=0&duration=3.2`,
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

async function writeContactSheet(currentPage, entries) {
  await currentPage.setViewportSize({ width: 1600, height: 900 });
  const cards = entries.map(({ id, image }, index) => `
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
  await currentPage.screenshot({ path: join(output, "contact-sheet.png"), fullPage: true });
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
