import { createIcons, ExternalLink, Info, Pause, Play, X } from "lucide";
import { exerciseInstructions } from "./guidance";
import rawMediaDescriptors from "./exercise-media.json";

type MediaDescriptor = {
  gif?: string;
  video?: string;
  unmappedGifReason?: string;
};
const mediaDescriptors =
  rawMediaDescriptors as Record<string, MediaDescriptor>;
const debugMediaBase =
  "https://raw.githubusercontent.com/omercotkd/exercises-gifs/" +
  "ebf642cd90fdf73a6c73e7127e93b607b12c229e/assets";

const exerciseId =
  new URLSearchParams(window.location.search).get("exercise") ??
  "barbell_back_squat";
const guide = exerciseInstructions(exerciseId);
const image = required<HTMLImageElement>("motion");
const still = required<HTMLCanvasElement>("motion-still");
const loading = required<HTMLElement>("loading");
const error = required<HTMLElement>("error");
const motionToggle = required<HTMLButtonElement>("motion-toggle");
const playbackPlay = required<HTMLElement>("playback-play");
const playbackPause = required<HTMLElement>("playback-pause");
const infoButton = required<HTMLButtonElement>("info");
const instructions = required<HTMLElement>("instructions");
const closeButton = required<HTMLButtonElement>("close");
const reduceMotion =
  new URLSearchParams(window.location.search).get("reduceMotion") === "1";
let paused = false;

createIcons({ icons: { ExternalLink, Info, Pause, Play, X } });
populateInstructions();

const mediaId = mediaDescriptors[exerciseId]?.gif;
if (mediaId) {
  image.src = `${debugMediaBase}/${mediaId}.gif`;
} else {
  showError();
}

image.addEventListener("load", () => {
  loading.hidden = true;
  image.hidden = false;
  if (reduceMotion) setPaused(true);
  document.body.dataset.ready = "true";
});
image.addEventListener("error", showError);
motionToggle.addEventListener("click", togglePlayback);
infoButton.addEventListener("click", () => {
  instructions.hidden = false;
});
closeButton.addEventListener("click", () => {
  instructions.hidden = true;
});
instructions.addEventListener("click", (event) => {
  if (event.target === instructions) instructions.hidden = true;
});

function showError(): void {
  loading.hidden = true;
  image.hidden = true;
  still.hidden = true;
  error.hidden = false;
  document.body.dataset.error = "true";
}

function populateInstructions(): void {
  required<HTMLElement>("instruction-title").textContent = guide.title;
  required<HTMLElement>("instruction-setup").textContent = guide.setup;
  required<HTMLElement>("instruction-movement").textContent = guide.movement;
  required<HTMLElement>("instruction-breathing").textContent = guide.breathing;
  required<HTMLElement>("instruction-tempo").textContent = guide.tempo;
  required<HTMLElement>("instruction-safety").textContent = guide.safety;
}

function togglePlayback(): void {
  if (image.hidden && still.hidden) return;
  setPaused(!paused);
}

function setPaused(nextPaused: boolean): void {
  if (nextPaused === paused && !(nextPaused && still.hidden)) return;
  paused = nextPaused;
  if (paused) {
    const width = image.naturalWidth;
    const height = image.naturalHeight;
    if (width > 0 && height > 0) {
      still.width = width;
      still.height = height;
      const context = still.getContext("2d");
      context?.drawImage(image, 0, 0, width, height);
      still.hidden = false;
      image.hidden = true;
    }
  } else {
    still.hidden = true;
    image.hidden = false;
  }
  renderPlaybackControl();
}

function renderPlaybackControl(): void {
  const action = paused ? "Play exercise animation" : "Pause exercise animation";
  playbackPlay.hidden = !paused;
  playbackPause.hidden = paused;
  motionToggle.setAttribute("aria-label", action);
  motionToggle.title = action;
}

function required<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`Missing #${id}`);
  return node as T;
}
