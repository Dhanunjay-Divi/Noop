import bodyPaths from "./body-paths";

type Side = "front" | "back";
type PathView = {
  vb: string;
  p: Record<string, string[]>;
};
type BodyMapConfiguration = {
  mode?: string;
  selected?: string[];
  scores?: Record<string, number>;
};

const params = new URLSearchParams(window.location.search);
let selected = new Set(
  (params.get("selected") ?? "").split(",").filter(Boolean),
);
let mode = params.get("mode") === "recovery" ? "recovery" : "load";
let scores = parseScores(params.get("scores"));
const geometry = bodyPaths.male;

const inert = new Set(["head", "hair", "neck", "hands", "feet", "knees", "ankles"]);
const noopMuscleByGeometry: Record<string, string> = {
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

(window as typeof window & {
  noopBodyMapUpdate: (configuration: BodyMapConfiguration) => void;
}).noopBodyMapUpdate = applyConfiguration;
render("front", geometry.front);
render("back", geometry.back);
document.body.dataset.ready = "true";

function render(side: Side, view: PathView): void {
  const svg = required<SVGSVGElement>(side);
  svg.setAttribute("viewBox", view.vb);

  for (const [geometryMuscle, paths] of Object.entries(view.p)) {
    const noopMuscle = noopMuscleByGeometry[geometryMuscle];
    for (const pathData of paths) {
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      path.setAttribute("d", pathData);
      if (!noopMuscle || inert.has(geometryMuscle)) {
        path.classList.add("inert");
        path.setAttribute("aria-hidden", "true");
      } else {
        configureMusclePath(path, noopMuscle);
      }
      svg.append(path);
    }
  }
}

function configureMusclePath(path: SVGPathElement, muscle: string): void {
  path.classList.add("muscle");
  path.dataset.muscle = muscle;
  path.setAttribute("role", "button");
  path.setAttribute("tabindex", "0");
  const title = document.createElementNS("http://www.w3.org/2000/svg", "title");
  title.textContent = displayName(muscle);
  path.append(title);
  path.addEventListener("click", () => selectMuscle(muscle));
  path.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    if (event.key === " ") event.preventDefault();
    selectMuscle(muscle);
  });
  refreshMusclePath(path);
}

function selectMuscle(muscle: string): void {
  if (selected.has(muscle)) {
    selected.delete(muscle);
  } else {
    selected.add(muscle);
  }
  document.querySelectorAll<SVGPathElement>(`path[data-muscle="${muscle}"]`)
    .forEach(refreshMusclePath);
  window.location.href = `noop-body-map://select/${encodeURIComponent(muscle)}`;
}

function applyConfiguration(configuration: BodyMapConfiguration): void {
  mode = configuration.mode === "recovery" ? "recovery" : "load";
  selected = new Set(configuration.selected?.filter(Boolean) ?? []);
  scores = Object.fromEntries(
    Object.entries(configuration.scores ?? {}).filter(([, value]) =>
      Number.isFinite(value)
    ),
  );
  document.querySelectorAll<SVGPathElement>("path.muscle")
    .forEach(refreshMusclePath);
}

function refreshMusclePath(path: SVGPathElement): void {
  const muscle = path.dataset.muscle;
  if (!muscle) return;
  const score = clamp(scores[muscle] ?? 0);
  const isSelected = selected.has(muscle);
  path.classList.toggle("selected", isSelected);
  path.style.fill = muscleColor(score);
  path.setAttribute("aria-pressed", String(isSelected));
  path.setAttribute(
    "aria-label",
    `${displayName(muscle)}, ${Math.round(score * 100)} percent ${mode}`,
  );
}

function parseScores(raw: string | null): Record<string, number> {
  if (!raw) return {};
  return Object.fromEntries(
    raw.split(",").flatMap((entry) => {
      const [muscle, value] = entry.split(":");
      const parsed = Number(value);
      return muscle && Number.isFinite(parsed) ? [[muscle, parsed]] : [];
    }),
  );
}

function displayName(muscle: string): string {
  const names: Record<string, string> = {
    chest: "Chest",
    back: "Back",
    shoulders: "Shoulders",
    biceps: "Biceps",
    triceps: "Triceps",
    forearms: "Forearms",
    core: "Core",
    quadriceps: "Quadriceps",
    hamstrings: "Hamstrings",
    glutes: "Glutes",
    calves: "Calves",
  };
  return names[muscle] ?? muscle;
}

function clamp(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function muscleColor(score: number): string {
  const intensity = Math.sqrt(clamp(score));
  const channels = [
    Math.round(52 + (235 - 52) * intensity),
    Math.round(55 + (31 - 55) * intensity),
    Math.round(63 + (46 - 63) * intensity),
  ];
  return `rgb(${channels.join(", ")})`;
}

function required<T extends Element>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`Missing #${id}`);
  return node as unknown as T;
}
