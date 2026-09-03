import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = fileURLToPath(new URL(".", import.meta.url));
const manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const mappings = JSON.parse(
  await readFile(join(root, "exercise-media.json"), "utf8"),
);
const exercises = manifest.exercises.map(({ id }) => id);
const localGifRoot = process.env.NOOP_STRENGTH_GIF_DIR?.trim() || null;
const debugMediaBase =
  "https://raw.githubusercontent.com/omercotkd/exercises-gifs/" +
  "ebf642cd90fdf73a6c73e7127e93b607b12c229e/assets";

assert.deepEqual(
  new Set(Object.keys(mappings)),
  new Set(exercises),
  "media mapping keys must match manifest",
);
const gifMappings = Object.values(mappings).filter(({ gif }) => gif);
const videoMappings = Object.values(mappings).filter(({ video }) => video);
assert.equal(gifMappings.length, 51, "exact GIF mapping count changed");
assert.equal(videoMappings.length, 19, "HD video mapping count changed");
for (const id of exercises) {
  const descriptor = mappings[id];
  assert(descriptor, `missing media descriptor for ${id}`);
  assert(
    descriptor.gif || descriptor.unmappedGifReason,
    `${id}: missing GIF mapping must explain why`,
  );
}
assert.equal(mappings.barbell_hip_thrust.gif, undefined);
assert.equal(mappings.barbell_hip_thrust.video, "0057");
assert.equal(mappings.treadmill_run.gif, "0684");
assert.equal(mappings.rowing_ergometer.video, "0077");
assert.equal(mappings.rowing_ergometer.gif, undefined);
assert.equal(mappings.side_plank.gif, undefined);

const failures = [];
const reachabilityFailures = [];
await Promise.all(exercises.flatMap((id) => {
  const mediaId = mappings[id].gif;
  if (!mediaId) return [];
  return [async () => {
  try {
    const response = await fetch(
      `${debugMediaBase}/${mediaId}.gif`,
      { signal: AbortSignal.timeout(15_000) },
    );
    const isGif = response.ok && response.headers.get("content-type")?.includes("image/gif");
    await response.body?.cancel();
    if (!isGif) {
      reachabilityFailures.push(`${id}: media returned ${response.status}`);
    }
  } catch (error) {
    reachabilityFailures.push(
      `${id}: media check failed (${error instanceof Error ? error.message : String(error)})`,
    );
  }
  }];
}).map((check) => check()));

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const relative = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const file = ["viewer.js", "body-map.js"].includes(relative)
      ? join(root, "dist", relative)
      : join(root, relative);
    response.setHeader("Content-Type", mimeType(file));
    response.end(await readFile(file));
  } catch {
    response.statusCode = 404;
    response.end("Not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
assert(address && typeof address === "object");

const browser = await chromium.launch({ channel: "chrome", headless: true });
const exerciseQueue = [...exercises];
await Promise.all(Array.from({ length: 6 }, async () => {
  const workerPage = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await configureLocalMedia(workerPage);
  workerPage.setDefaultTimeout(10_000);
  while (exerciseQueue.length) {
    const id = exerciseQueue.shift();
    if (!id) break;
    try {
      await workerPage.goto(
        `http://127.0.0.1:${address.port}/?exercise=${id}`,
        { waitUntil: "domcontentloaded", timeout: 10_000 },
      );
      if (mappings[id].gif) {
        await workerPage.locator("body[data-ready='true']").waitFor();
        assert((await workerPage.locator("#motion").evaluate((image) => image.naturalWidth)) > 0);
      } else {
        await workerPage.locator("body[data-error='true']").waitFor();
        assert((await workerPage.locator("#error").textContent())?.trim().length > 0);
      }
      assert.equal(await workerPage.locator(".caption").count(), 0);
    } catch (error) {
      failures.push(`${id}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  await workerPage.close();
}));

const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
await configureLocalMedia(page);
page.setDefaultTimeout(10_000);
await page.goto(
  "http://127.0.0.1:" + address.port + "/?exercise=barbell_back_squat",
  { waitUntil: "domcontentloaded", timeout: 10_000 },
);
await page.locator("body[data-ready='true']").waitFor();
await page.locator("#motion-toggle").click();
assert.equal(await page.locator("#motion-still").getAttribute("hidden"), null);
assert.notEqual(await page.locator("#motion").getAttribute("hidden"), null);
assert.equal(await page.locator("#playback-play").getAttribute("hidden"), null);
assert.notEqual(await page.locator("#playback-pause").getAttribute("hidden"), null);
await page.locator("#motion-toggle").click();
assert.equal(await page.locator("#motion").getAttribute("hidden"), null);
assert.equal(await page.locator("#playback-pause").getAttribute("hidden"), null);
assert.notEqual(await page.locator("#playback-play").getAttribute("hidden"), null);
assert.equal(await page.locator("#playback").count(), 0);
await page.setViewportSize({ width: 390, height: 241 });
const motionBox = await page.locator("#motion").boundingBox();
const guideBox = await page.locator(".guide").boundingBox();
assert(motionBox && guideBox, "exercise media must have visible bounds");
assert(Math.abs(motionBox.width - motionBox.height) < 1, "square media must preserve its aspect");
assert(
  motionBox.width <= guideBox.width + 1 &&
    motionBox.height <= guideBox.height + 1,
);
await page.screenshot({ path: "/tmp/noop-strength-motion-exercisedb.png" });
await page.locator("#info").click();
assert.equal(await page.locator("#instructions").getAttribute("hidden"), null);
for (const id of ["instruction-setup", "instruction-movement", "instruction-safety"]) {
  assert((await page.locator(`#${id}`).textContent())?.trim().length >= 24);
}
await page.setViewportSize({ width: 390, height: 844 });
await page.screenshot({ path: "/tmp/noop-strength-motion-instructions.png" });

await page.goto(
  `http://127.0.0.1:${address.port}/body-map.html` +
    "?mode=load&selected=chest%2Cback&scores=chest%3A0.8%2Cback%3A0.4%2Cquadriceps%3A1",
);
await page.setViewportSize({ width: 390, height: 306 });
await page.locator("body[data-ready='true']").waitFor();
assert.equal(await page.locator("svg").count(), 2);
assert((await page.locator("path.muscle").count()) > 20);
assert((await page.locator('path[data-muscle="chest"].selected').count()) > 0);
assert((await page.locator('path[data-muscle="back"].selected').count()) > 0);
assert((await page.locator('path[data-muscle="quadriceps"]').count()) > 0);
for (const muscle of ["chest", "back"]) {
  assert.equal(
    await page.locator(`path[data-muscle="${muscle}"]`).first()
      .evaluate((node) => getComputedStyle(node).fill),
    "rgb(255, 52, 69)",
    `${muscle} selection must be visibly highlighted`,
  );
}
for (const box of await page.locator("svg").evaluateAll((nodes) =>
  nodes.map((node) => node.getBoundingClientRect().toJSON())
)) {
  assert(box.width > 0 && box.height > 0, "body-map figures must have visible bounds");
}
await page.screenshot({ path: "/tmp/noop-strength-body-map.png" });
await page.evaluate(() => {
  window.noopBodyMapUpdate({
    mode: "recovery",
    selected: ["quadriceps", "glutes"],
    scores: { quadriceps: 0.2, glutes: 0.7 },
  });
});
assert.equal(await page.locator('path[data-muscle="chest"].selected').count(), 0);
assert.equal(await page.locator('path[data-muscle="back"].selected').count(), 0);
assert((await page.locator('path[data-muscle="quadriceps"].selected').count()) > 0);
assert((await page.locator('path[data-muscle="glutes"].selected').count()) > 0);
for (const muscle of ["quadriceps", "glutes"]) {
  assert.equal(
    await page.locator(`path[data-muscle="${muscle}"]`).first()
      .evaluate((node) => getComputedStyle(node).fill),
    "rgb(255, 52, 69)",
    `${muscle} selection must remain visibly highlighted after updates`,
  );
}

await browser.close();
await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));

if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  if (reachabilityFailures.length) {
    console.warn(
      `Remote reachability warnings (${reachabilityFailures.length}):\n` +
        reachabilityFailures.join("\n"),
    );
  }
  console.log(
    `QA passed: ${exercises.length} reviewed, ${gifMappings.length} GIF guides rendered` +
      (localGifRoot ? " from the configured source archive" : ""),
  );
}

async function configureLocalMedia(page) {
  if (!localGifRoot) return;
  await page.route(`${debugMediaBase}/*.gif`, async (route) => {
    const mediaId = new URL(route.request().url()).pathname.split("/").pop();
    try {
      const body = await readFile(join(localGifRoot, mediaId ?? ""));
      await route.fulfill({ status: 200, contentType: "image/gif", body });
    } catch {
      await route.abort("failed");
    }
  });
}

function mimeType(file) {
  switch (extname(file)) {
    case ".html": return "text/html; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    default: return "application/octet-stream";
  }
}
