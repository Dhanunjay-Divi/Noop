import { createIcons, ExternalLink, Info, Pause, Play, X } from "lucide";
import { exerciseInstructions } from "./guidance";

const mediaIds: Record<string, string> = {
  barbell_back_squat: "qXTaZnJ",
  barbell_bench_press: "EIeI8Vf",
  conventional_deadlift: "ila4NZS",
  overhead_press: "wdRZISl",
  bent_over_row: "eZyBC3j",
  pull_up: "lBDjFxJ",
  lat_pulldown: "CuaWCmC",
  leg_press: "2Qh2J1e",
  romanian_deadlift: "wQ2c4XD",
  dumbbell_lunge: "RRWFUcw",
  biceps_curl: "NbVPDMW",
  triceps_pushdown: "3ZflifB",
  plank: "VBAWRPG",
  barbell_front_squat: "zG0zs85",
  goblet_squat: "yn8yg1r",
  hack_squat: "Qa55kX1",
  leg_extension: "my33uHU",
  lying_leg_curl: "17lJ1kr",
  barbell_hip_thrust: "qKBpF7I",
  glute_bridge: "u0cNiij",
  bulgarian_split_squat: "qx4fgX7",
  walking_lunge: "IZVHb27",
  standing_calf_raise: "8ozhUIZ",
  seated_calf_raise: "ktsFQAZ",
  incline_barbell_bench_press: "3TZduzM",
  dumbbell_bench_press: "SpYC0Kp",
  push_up: "I4hDWkc",
  chest_fly: "yz9nUhF",
  cable_crossover: "j7XMAyn",
  machine_chest_press: "T0yTjgW",
  one_arm_dumbbell_row: "7vG5o25",
  seated_cable_row: "fUBheHs",
  chest_supported_row: "7vG5o25",
  chin_up: "T2mxWqc",
  face_pull: "wqNPGCg",
  dumbbell_shoulder_press: "znQUdHY",
  lateral_raise: "DsgkuIt",
  rear_delt_fly: "mu5Guxt",
  hammer_curl: "slDvUAU",
  preacher_curl: "qOgPVf6",
  skull_crusher: "h8LFzo9",
  overhead_triceps_extension: "2IxROQ1",
  parallel_bar_dip: "X6C6i5Y",
  hanging_leg_raise: "I3tsCnC",
  cable_crunch: "WW95auq",
  side_plank: "5VXmnV5",
  ab_wheel_rollout: "NAgVB3t",
  farmers_carry: "qPEzJjA",
  kettlebell_swing: "UHJlbu3",
  back_extension: "rUXfn3R",
  band_pull_apart: "tc5dYrf",
  resistance_band_row: "Nu7jqFE",
  treadmill_run: "rjiM4L3",
  indoor_cycling: "H1PESYI",
  rowing_ergometer: "7I6LNUG",
  stair_climber: "j9Q5crt",
};

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

const mediaId = mediaIds[exerciseId];
if (mediaId) {
  image.src = `https://static.exercisedb.dev/media/${mediaId}.gif`;
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
