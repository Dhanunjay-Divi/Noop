import { createIcons, Info, Pause, Play, RotateCcw, X } from "lucide";
import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { exerciseInstructions } from "./guidance";
import { ExerciseMannequin } from "./mannequin";

interface MotionSegment {
  id: string;
}

interface MotionManifest {
  exercises: MotionSegment[];
}

type DynamicEquipment = "barbell" | "dumbbells" | "kettlebell" | "band" | "none";

const query = new URLSearchParams(window.location.search);
const exerciseId = query.get("exercise") ?? "barbell_back_squat";
const cycleSeconds = Math.max(1.2, Number(query.get("duration") ?? "3.2"));
const stillPhase = THREE.MathUtils.clamp(Number(query.get("phase") ?? "0.22"), 0, 1);
const reduceMotion =
  query.get("reduceMotion") === "1" ||
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const canvas = required<HTMLCanvasElement>("motion");
const loading = required<HTMLElement>("loading");
const error = required<HTMLElement>("error");
const infoButton = required<HTMLButtonElement>("info");
const pauseButton = required<HTMLButtonElement>("pause");
const resetButton = required<HTMLButtonElement>("reset");
const instructionsSheet = required<HTMLElement>("instructions");
const closeButton = required<HTMLButtonElement>("close");

createIcons({ icons: { Info, Pause, Play, RotateCcw, X } });
populateInstructions();

const renderer = new THREE.WebGLRenderer({
  canvas,
  antialias: true,
  alpha: false,
  powerPreference: "high-performance",
});
renderer.setClearColor(0x08090c, 1);
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.08;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x08090c);
scene.fog = new THREE.Fog(0x08090c, 4.8, 8.2);

const camera = new THREE.PerspectiveCamera(35, 1, 0.02, 30);
const controls = new OrbitControls(camera, canvas);
controls.enableDamping = true;
controls.dampingFactor = 0.07;
controls.enablePan = false;
controls.rotateSpeed = 0.68;
controls.zoomSpeed = 0.72;
controls.minPolarAngle = Math.PI * 0.13;
controls.maxPolarAngle = Math.PI * 0.84;
controls.touches.ONE = THREE.TOUCH.ROTATE;
controls.touches.TWO = THREE.TOUCH.DOLLY_ROTATE;

scene.add(new THREE.HemisphereLight(0xf5f4f2, 0x171a20, 1.45));
const key = new THREE.DirectionalLight(0xfff2ed, 3.2);
key.position.set(-2.6, 4.5, 3.2);
key.castShadow = true;
key.shadow.mapSize.set(1024, 1024);
key.shadow.camera.near = 0.1;
key.shadow.camera.far = 9;
key.shadow.camera.left = -2.8;
key.shadow.camera.right = 2.8;
key.shadow.camera.top = 3.2;
key.shadow.camera.bottom = -1.2;
key.shadow.bias = -0.00025;
scene.add(key);
const rim = new THREE.DirectionalLight(0xff3948, 1.25);
rim.position.set(3.4, 2.8, -2.5);
scene.add(rim);

const floorMaterial = new THREE.MeshStandardMaterial({
  color: 0x111318,
  roughness: 0.82,
  metalness: 0.04,
});
const floor = new THREE.Mesh(new THREE.CircleGeometry(4.2, 96), floorMaterial);
floor.rotation.x = -Math.PI / 2;
floor.position.y = -0.012;
floor.receiveShadow = true;
scene.add(floor);

let mannequin: ExerciseMannequin | undefined;
let equipment: ExerciseEquipment | undefined;
let paused = reduceMotion;
let frozenPhase = reduceMotion ? stillPhase : 0;
let resumedAt = performance.now();
let pausedBeforeInstructions = paused;
let homePosition = new THREE.Vector3(2.6, 1.4, 3.8);
let homeTarget = new THREE.Vector3(0, 0.95, 0);

new ResizeObserver(resize).observe(canvas);
resize();
void loadScene();

infoButton.addEventListener("click", openInstructions);
pauseButton.addEventListener("click", togglePaused);
resetButton.addEventListener("click", resetCamera);
closeButton.addEventListener("click", closeInstructions);
instructionsSheet.addEventListener("click", (event) => {
  if (event.target === instructionsSheet) closeInstructions();
});
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !instructionsSheet.hidden) closeInstructions();
});

async function loadScene(): Promise<void> {
  try {
    const manifestResponse = await fetch("manifest.json");
    if (!manifestResponse.ok) throw new Error(`Manifest ${manifestResponse.status}`);
    const manifest = (await manifestResponse.json()) as MotionManifest;
    if (!manifest.exercises.some((candidate) => candidate.id === exerciseId)) {
      throw new Error(`No motion profile for ${exerciseId}`);
    }

    mannequin = new ExerciseMannequin();
    mannequin.pose(exerciseId, stillPhase);
    scene.add(mannequin.root);
    equipment = new ExerciseEquipment(scene, mannequin.root, exerciseId);
    equipment.update();
    frameCamera(mannequin.root);
    loading.hidden = true;
    document.body.dataset.ready = "true";
    requestAnimationFrame(animate);
  } catch (cause) {
    console.error(cause);
    loading.hidden = true;
    error.hidden = false;
    document.body.dataset.error = "true";
  }
}

function animate(now: number): void {
  if (mannequin) {
    mannequin.pose(exerciseId, currentPhase(now));
    equipment?.update();
  }
  controls.update();
  renderer.render(scene, camera);
  requestAnimationFrame(animate);
}

function currentPhase(now: number): number {
  if (paused) return frozenPhase;
  return (frozenPhase + (now - resumedAt) / 1000 / cycleSeconds) % 1;
}

function setPaused(nextPaused: boolean): void {
  if (nextPaused === paused) return;
  const now = performance.now();
  if (nextPaused) {
    frozenPhase = currentPhase(now);
  } else {
    resumedAt = now;
  }
  paused = nextPaused;
  pauseButton.innerHTML = `<i data-lucide="${paused ? "play" : "pause"}"></i>`;
  pauseButton.ariaLabel = paused ? "Play animation" : "Pause animation";
  pauseButton.title = pauseButton.ariaLabel;
  createIcons({ icons: { Pause, Play } });
}

function togglePaused(): void {
  setPaused(!paused);
}

function openInstructions(): void {
  pausedBeforeInstructions = paused;
  setPaused(true);
  instructionsSheet.hidden = false;
  closeButton.focus();
}

function closeInstructions(): void {
  instructionsSheet.hidden = true;
  setPaused(pausedBeforeInstructions);
  infoButton.focus();
}

function resetCamera(): void {
  camera.position.copy(homePosition);
  controls.target.copy(homeTarget);
  controls.update();
}

function frameCamera(model: THREE.Object3D): void {
  const bounds = new THREE.Box3().setFromObject(model);
  const size = bounds.getSize(new THREE.Vector3());
  const center = bounds.getCenter(new THREE.Vector3());
  const maximum = Math.max(size.x, size.y, size.z, 1.2);
  const distance = maximum * 2;
  const direction = new THREE.Vector3(0.68, 0.24, 1).normalize();
  homeTarget.copy(center);
  homeTarget.y += size.y * 0.02;
  homePosition.copy(homeTarget).addScaledVector(direction, distance);
  controls.minDistance = maximum * 0.72;
  controls.maxDistance = maximum * 3.4;
  resetCamera();
}

function resize(): void {
  const width = Math.max(1, canvas.clientWidth);
  const height = Math.max(1, canvas.clientHeight);
  renderer.setSize(width, height, false);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}

function populateInstructions(): void {
  const guide = exerciseInstructions(exerciseId);
  required<HTMLElement>("instruction-title").textContent = guide.title;
  required<HTMLElement>("instruction-setup").textContent = guide.setup;
  required<HTMLElement>("instruction-movement").textContent = guide.movement;
  required<HTMLElement>("instruction-breathing").textContent = guide.breathing;
  required<HTMLElement>("instruction-tempo").textContent = guide.tempo;
  required<HTMLElement>("instruction-safety").textContent = guide.safety;
}

function required<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element as T;
}

class ExerciseEquipment {
  private readonly root = new THREE.Group();
  private readonly dynamicKind: DynamicEquipment;
  private readonly dynamic: THREE.Group | undefined;
  private readonly bandLine: THREE.Line | undefined;
  private readonly leftHand: THREE.Object3D | undefined;
  private readonly rightHand: THREE.Object3D | undefined;
  private readonly hips: THREE.Object3D | undefined;
  private readonly upperSpine: THREE.Object3D | undefined;
  private readonly pullUpFrame: THREE.Group | undefined;
  private readonly leftPosition = new THREE.Vector3();
  private readonly rightPosition = new THREE.Vector3();
  private readonly hipsPosition = new THREE.Vector3();

  constructor(scene: THREE.Scene, model: THREE.Object3D, private readonly id: string) {
    scene.add(this.root);
    this.leftHand = findBone(model, "lefthand");
    this.rightHand = findBone(model, "righthand");
    this.hips = findBone(model, "hips");
    this.upperSpine = findBone(model, "spine2");
    this.dynamicKind = dynamicEquipment(id);

    if (this.dynamicKind === "barbell") {
      this.dynamic = makeBarbell();
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "dumbbells") {
      this.dynamic = new THREE.Group();
      this.dynamic.add(makeDumbbell(), makeDumbbell());
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "kettlebell") {
      this.dynamic = makeKettlebell();
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "band") {
      this.bandLine = new THREE.Line(
        new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3()]),
        new THREE.LineBasicMaterial({ color: 0xed2435, linewidth: 2 }),
      );
      this.root.add(this.bandLine);
    }
    addStructuralEquipment(this.root, id);
    this.pullUpFrame = this.root.getObjectByName("PullUpFrame") as THREE.Group | undefined;
  }

  update(): void {
    this.leftHand?.getWorldPosition(this.leftPosition);
    this.rightHand?.getWorldPosition(this.rightPosition);
    this.hips?.getWorldPosition(this.hipsPosition);
    if (this.pullUpFrame && this.leftHand && this.rightHand) {
      this.pullUpFrame.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
    }

    if (this.dynamicKind === "barbell" && this.dynamic) {
      const hipMounted = this.id === "barbell_hip_thrust";
      const shoulderMounted =
        this.id === "barbell_back_squat" || this.id === "barbell_front_squat";
      if (hipMounted) {
        this.dynamic.position.copy(this.hipsPosition);
        this.dynamic.position.y += 0.04;
        this.dynamic.quaternion.identity();
      } else if (shoulderMounted && this.upperSpine) {
        this.upperSpine.getWorldPosition(this.dynamic.position);
        this.dynamic.position.y += 0.08;
        this.dynamic.position.z += this.id === "barbell_back_squat" ? -0.09 : 0.11;
        this.dynamic.quaternion.identity();
      } else if (this.leftHand && this.rightHand) {
        this.dynamic.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
        this.dynamic.quaternion.identity();
      }
    } else if (this.dynamicKind === "dumbbells" && this.dynamic) {
      const [left, right] = this.dynamic.children;
      left.position.copy(this.leftPosition);
      right.position.copy(this.rightPosition);
    } else if (
      this.dynamicKind === "kettlebell" &&
      this.dynamic &&
      this.leftHand &&
      this.rightHand
    ) {
      this.dynamic.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
      this.dynamic.position.y -= 0.13;
    } else if (this.bandLine && this.leftHand && this.rightHand) {
      const positions = this.bandLine.geometry.attributes.position as THREE.BufferAttribute;
      positions.setXYZ(0, this.leftPosition.x, this.leftPosition.y, this.leftPosition.z);
      positions.setXYZ(1, this.rightPosition.x, this.rightPosition.y, this.rightPosition.z);
      positions.needsUpdate = true;
      this.bandLine.geometry.computeBoundingSphere();
    }
  }
}

const red = new THREE.MeshStandardMaterial({
  color: 0xc91327,
  roughness: 0.5,
  metalness: 0.12,
});
const graphite = new THREE.MeshStandardMaterial({
  color: 0x282b31,
  roughness: 0.55,
  metalness: 0.38,
});
const rubber = new THREE.MeshStandardMaterial({
  color: 0x0e0f12,
  roughness: 0.82,
  metalness: 0.02,
});

function makeBarbell(): THREE.Group {
  const group = new THREE.Group();
  group.add(cylinder(0.016, 1.58, graphite, "x"));
  for (const direction of [-1, 1]) {
    const plate = cylinder(0.145, 0.055, rubber, "x");
    plate.position.x = direction * 0.63;
    group.add(plate);
    const collar = cylinder(0.045, 0.045, red, "x");
    collar.position.x = direction * 0.56;
    group.add(collar);
  }
  markShadows(group);
  return group;
}

function makeDumbbell(): THREE.Group {
  const group = new THREE.Group();
  group.add(cylinder(0.016, 0.34, graphite, "x"));
  for (const direction of [-1, 1]) {
    const plate = cylinder(0.09, 0.075, rubber, "x");
    plate.position.x = direction * 0.13;
    group.add(plate);
    const cap = cylinder(0.07, 0.012, red, "x");
    cap.position.x = direction * 0.173;
    group.add(cap);
  }
  markShadows(group);
  return group;
}

function makeKettlebell(): THREE.Group {
  const group = new THREE.Group();
  const bell = new THREE.Mesh(new THREE.SphereGeometry(0.13, 24, 18), rubber);
  bell.scale.y = 0.86;
  group.add(bell);
  const handle = new THREE.Mesh(new THREE.TorusGeometry(0.095, 0.018, 12, 28, Math.PI), red);
  handle.rotation.z = Math.PI;
  handle.position.y = 0.13;
  group.add(handle);
  markShadows(group);
  return group;
}

function addStructuralEquipment(root: THREE.Group, id: string): void {
  if (benchExercises.has(id)) addBench(root, id.includes("incline"));
  if (barExercises.has(id)) addPullUpBar(root);
  if (cableExercises.has(id)) addCableTower(root);
  if (machineExercises.has(id)) addMachineFrame(root, id);
  if (id === "treadmill_run") addTreadmill(root);
  if (id === "indoor_cycling") addCycle(root);
  if (id === "rowing_ergometer") addRower(root);
  if (id === "stair_climber") addStairs(root);
  markShadows(root);
}

function addBench(root: THREE.Group, inclined: boolean): void {
  const bench = new THREE.Group();
  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.11, 1.35), rubber);
  pad.position.set(0, 0.2, 0.08);
  if (inclined) {
    pad.rotation.x = -0.38;
    pad.position.y = 0.3;
    pad.position.z = 0.08;
  }
  bench.add(pad);
  for (const z of [-0.43, 0.43]) {
    const leg = new THREE.Mesh(new THREE.BoxGeometry(0.48, 0.05, 0.08), graphite);
    leg.position.set(0, 0.045, z);
    bench.add(leg);
    const post = new THREE.Mesh(new THREE.BoxGeometry(0.055, 0.3, 0.055), graphite);
    post.position.set(0, 0.1, z);
    bench.add(post);
  }
  root.add(bench);
}

function addPullUpBar(root: THREE.Group): void {
  const frame = new THREE.Group();
  frame.name = "PullUpFrame";
  const bar = cylinder(0.025, 1.55, graphite, "x");
  frame.add(bar);
  for (const x of [-0.82, 0.82]) {
    const upright = cylinder(0.022, 2.2, graphite, "y");
    upright.position.set(x, -1.1, 0.24);
    frame.add(upright);
  }
  root.add(frame);
}

function addCableTower(root: THREE.Group): void {
  for (const x of [-0.72, 0.72]) {
    const tower = new THREE.Mesh(new THREE.BoxGeometry(0.09, 1.9, 0.12), graphite);
    tower.position.set(x, 0.95, -0.58);
    root.add(tower);
  }
  const crossbar = new THREE.Mesh(new THREE.BoxGeometry(1.53, 0.08, 0.1), graphite);
  crossbar.position.set(0, 1.88, -0.58);
  root.add(crossbar);
}

function addMachineFrame(root: THREE.Group, id: string): void {
  const frame = new THREE.Group();
  const base = new THREE.Mesh(new THREE.BoxGeometry(0.92, 0.06, 0.92), graphite);
  base.position.set(0, 0.03, -0.2);
  frame.add(base);
  const seat = new THREE.Mesh(new THREE.BoxGeometry(0.52, 0.09, 0.46), rubber);
  seat.position.set(0, id === "leg_press" ? 0.3 : 0.42, -0.2);
  frame.add(seat);
  const back = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.65, 0.08), rubber);
  back.position.set(0, 0.72, -0.43);
  back.rotation.x = id === "leg_press" ? -0.56 : 0;
  frame.add(back);
  for (const x of [-0.42, 0.42]) {
    const upright = cylinder(0.025, 1.4, graphite, "y");
    upright.position.set(x, 0.7, -0.5);
    frame.add(upright);
  }
  root.add(frame);
}

function addTreadmill(root: THREE.Group): void {
  const deck = new THREE.Mesh(new THREE.BoxGeometry(0.78, 0.12, 1.85), rubber);
  deck.position.set(0, 0.07, 0);
  root.add(deck);
  const consolePost = new THREE.Mesh(new THREE.BoxGeometry(0.06, 1.05, 0.06), graphite);
  consolePost.position.set(0.37, 0.62, -0.68);
  root.add(consolePost);
}

function addCycle(root: THREE.Group): void {
  const wheel = new THREE.Mesh(new THREE.TorusGeometry(0.42, 0.035, 12, 48), graphite);
  wheel.rotation.y = Math.PI / 2;
  wheel.position.set(0, 0.46, 0.1);
  root.add(wheel);
  const post = cylinder(0.035, 0.78, graphite, "y");
  post.position.set(0, 0.68, 0);
  post.rotation.z = -0.2;
  root.add(post);
  const seat = new THREE.Mesh(new THREE.BoxGeometry(0.36, 0.06, 0.18), rubber);
  seat.position.set(0, 1.02, 0.13);
  root.add(seat);
}

function addRower(root: THREE.Group): void {
  const rail = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.08, 1.9), graphite);
  rail.position.set(0, 0.24, 0);
  root.add(rail);
  const seat = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.08, 0.34), rubber);
  seat.position.set(0, 0.34, 0.12);
  root.add(seat);
  const flywheel = new THREE.Mesh(new THREE.CylinderGeometry(0.32, 0.32, 0.22, 36), rubber);
  flywheel.rotation.z = Math.PI / 2;
  flywheel.position.set(0, 0.38, -0.84);
  root.add(flywheel);
}

function addStairs(root: THREE.Group): void {
  for (let index = 0; index < 5; index += 1) {
    const step = new THREE.Mesh(
      new THREE.BoxGeometry(0.86, 0.12, 0.34),
      index % 2 === 0 ? rubber : graphite,
    );
    step.position.set(0, 0.06 + index * 0.12, 0.54 - index * 0.28);
    root.add(step);
  }
}

function cylinder(
  radius: number,
  length: number,
  material: THREE.Material,
  axis: "x" | "y",
): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, length, 24), material);
  if (axis === "x") mesh.rotation.z = Math.PI / 2;
  return mesh;
}

function markShadows(root: THREE.Object3D): void {
  root.traverse((object) => {
    if (object instanceof THREE.Mesh) {
      object.castShadow = true;
      object.receiveShadow = true;
    }
  });
}

function placeAcrossHands(
  object: THREE.Object3D,
  leftHand: THREE.Vector3,
  rightHand: THREE.Vector3,
): void {
  const direction = rightHand.clone().sub(leftHand);
  object.position.copy(leftHand).lerp(rightHand, 0.5);
  if (direction.lengthSq() > 0.0001) {
    object.quaternion.setFromUnitVectors(
      new THREE.Vector3(1, 0, 0),
      direction.normalize(),
    );
  }
}

function findBone(root: THREE.Object3D, normalizedName: string): THREE.Object3D | undefined {
  let match: THREE.Object3D | undefined;
  root.traverse((object) => {
    const normalized = object.name.toLowerCase().replace(/[^a-z]/g, "");
    if (!match && normalized.endsWith(normalizedName)) match = object;
  });
  return match;
}

function dynamicEquipment(id: string): DynamicEquipment {
  if (barbellExercises.has(id)) return "barbell";
  if (dumbbellExercises.has(id)) return "dumbbells";
  if (kettlebellExercises.has(id)) return "kettlebell";
  if (bandExercises.has(id)) return "band";
  return "none";
}

const barbellExercises = new Set([
  "barbell_back_squat",
  "barbell_front_squat",
  "barbell_bench_press",
  "incline_barbell_bench_press",
  "conventional_deadlift",
  "romanian_deadlift",
  "overhead_press",
  "bent_over_row",
  "barbell_hip_thrust",
  "skull_crusher",
]);

const dumbbellExercises = new Set([
  "dumbbell_lunge",
  "walking_lunge",
  "bulgarian_split_squat",
  "biceps_curl",
  "hammer_curl",
  "preacher_curl",
  "dumbbell_bench_press",
  "chest_fly",
  "one_arm_dumbbell_row",
  "chest_supported_row",
  "dumbbell_shoulder_press",
  "lateral_raise",
  "rear_delt_fly",
  "farmers_carry",
  "overhead_triceps_extension",
]);

const kettlebellExercises = new Set(["goblet_squat", "kettlebell_swing"]);
const bandExercises = new Set(["band_pull_apart", "resistance_band_row"]);
const benchExercises = new Set([
  "barbell_bench_press",
  "incline_barbell_bench_press",
  "dumbbell_bench_press",
  "chest_fly",
  "skull_crusher",
  "barbell_hip_thrust",
  "preacher_curl",
  "chest_supported_row",
  "lying_leg_curl",
  "back_extension",
]);
const barExercises = new Set(["pull_up", "chin_up", "hanging_leg_raise"]);
const cableExercises = new Set([
  "lat_pulldown",
  "triceps_pushdown",
  "cable_crossover",
  "seated_cable_row",
  "face_pull",
  "cable_crunch",
]);
const machineExercises = new Set([
  "leg_press",
  "hack_squat",
  "leg_extension",
  "lying_leg_curl",
  "machine_chest_press",
  "lat_pulldown",
  "seated_cable_row",
  "seated_calf_raise",
]);
