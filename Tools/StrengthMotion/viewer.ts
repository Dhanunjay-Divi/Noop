import {
  createIcons,
  Info,
  Pause,
  PersonStanding,
  Play,
  RotateCcw,
  UserRound,
  X,
} from "lucide";
import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { exerciseInstructions } from "./guidance";
import { ExerciseHumanoid } from "./humanoid";
import motionManifest from "./manifest.json";
import { ExerciseMannequin } from "./mannequin";

interface MotionSegment {
  id: string;
}

interface MotionManifest {
  exercises: MotionSegment[];
}

type DynamicEquipment =
  | "barbell"
  | "dumbbells"
  | "singleDumbbell"
  | "centerDumbbell"
  | "kettlebell"
  | "band"
  | "none";
type BodyStyle = "man" | "woman";

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
const bodyStyleButtons = Array.from(
  document.querySelectorAll<HTMLButtonElement>("[data-body-style]"),
);
const viewerIcons = { Info, Pause, PersonStanding, Play, RotateCcw, UserRound, X };
const modelURLs: Record<BodyStyle, string> = {
  man: new URL("./trainer-man.glb", window.location.href).href,
  woman: new URL("./trainer-woman.glb", window.location.href).href,
};

createIcons({ icons: viewerIcons });
populateInstructions();

const renderer = new THREE.WebGLRenderer({
  canvas,
  antialias: true,
  alpha: false,
  powerPreference: "high-performance",
  preserveDrawingBuffer: true,
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
let humanoid: ExerciseHumanoid | undefined;
let equipment: ExerciseEquipment | undefined;
let bodyStyle = initialBodyStyle();
let modelRequest = 0;
let paused = reduceMotion;
let frozenPhase = reduceMotion ? stillPhase : 0;
let resumedAt = performance.now();
let pausedBeforeInstructions = paused;
let homePosition = new THREE.Vector3(2.6, 1.4, 3.8);
let homeTarget = new THREE.Vector3(0, 0.95, 0);

updateBodyStyleButtons(false);
new ResizeObserver(resize).observe(canvas);
resize();
void Promise.resolve().then(loadScene);

infoButton.addEventListener("click", openInstructions);
pauseButton.addEventListener("click", togglePaused);
resetButton.addEventListener("click", resetCamera);
closeButton.addEventListener("click", closeInstructions);
for (const button of bodyStyleButtons) {
  button.addEventListener("click", () => {
    const next = button.dataset.bodyStyle;
    if (isBodyStyle(next)) void changeBodyStyle(next);
  });
}
instructionsSheet.addEventListener("click", (event) => {
  if (event.target === instructionsSheet) closeInstructions();
});
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !instructionsSheet.hidden) closeInstructions();
});

async function loadScene(): Promise<void> {
  try {
    const manifest = motionManifest as MotionManifest;
    if (!manifest.exercises.some((candidate) => candidate.id === exerciseId)) {
      throw new Error(`No motion profile for ${exerciseId}`);
    }

    mannequin = new ExerciseMannequin();
    mannequin.pose(exerciseId, stillPhase);
    scene.add(mannequin.root);
    let visualModel = mannequin.root;
    try {
      humanoid = await ExerciseHumanoid.load(modelURLs[bodyStyle], mannequin, exerciseId);
      mannequin.setBodyVisible(false);
      scene.add(humanoid.root);
      visualModel = humanoid.root;
      document.body.dataset.model = "humanoid";
      document.body.dataset.bodyStyle = bodyStyle;
    } catch (cause) {
      console.warn("Using procedural exercise model fallback", cause);
      document.body.dataset.model = "fallback";
    }
    equipment = new ExerciseEquipment(scene, visualModel, exerciseId);
    equipment.update();
    frameCamera(visualModel, equipment.root);
    renderer.render(scene, camera);
    loading.hidden = true;
    document.body.dataset.ready = "true";
    updateBodyStyleButtons(true);
    requestAnimationFrame(animate);
  } catch (cause) {
    console.error(cause);
    loading.hidden = true;
    error.hidden = false;
    document.body.dataset.error = "true";
  }
}

async function changeBodyStyle(next: BodyStyle): Promise<void> {
  if (!mannequin || next === bodyStyle) return;
  const request = ++modelRequest;
  updateBodyStyleButtons(false);
  document.body.dataset.switchingBody = "true";
  try {
    const replacement = await ExerciseHumanoid.load(
      modelURLs[next],
      mannequin,
      exerciseId,
    );
    if (request !== modelRequest) {
      replacement.dispose();
      return;
    }
    equipment?.dispose();
    humanoid?.dispose();
    humanoid = replacement;
    bodyStyle = next;
    scene.add(replacement.root);
    equipment = new ExerciseEquipment(scene, replacement.root, exerciseId);
    replacement.update();
    equipment.update();
    mannequin.setBodyVisible(false);
    frameCamera(replacement.root, equipment.root);
    storeBodyStyle(next);
    document.body.dataset.model = "humanoid";
    document.body.dataset.bodyStyle = next;
  } catch (cause) {
    console.error(`Unable to load ${next} trainer`, cause);
  } finally {
    if (request === modelRequest) {
      delete document.body.dataset.switchingBody;
      updateBodyStyleButtons(true);
    }
  }
}

function animate(now: number): void {
  if (mannequin) {
    mannequin.pose(exerciseId, currentPhase(now));
    humanoid?.update();
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
  createIcons({ icons: viewerIcons });
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

function frameCamera(...objects: THREE.Object3D[]): void {
  const bounds = new THREE.Box3();
  for (const object of objects) bounds.expandByObject(object);
  const size = bounds.getSize(new THREE.Vector3());
  const center = bounds.getCenter(new THREE.Vector3());
  const maximum = Math.max(size.x, size.y, size.z, 1.2);
  const distance = maximum * 1.92;
  const direction = defaultViewDirection(exerciseId);
  homeTarget.copy(center);
  homeTarget.y += size.y * 0.02;
  homePosition.copy(homeTarget).addScaledVector(direction, distance);
  controls.minDistance = maximum * 0.72;
  controls.maxDistance = maximum * 3.4;
  resetCamera();
}

function defaultViewDirection(id: string): THREE.Vector3 {
  if (id === "barbell_hip_thrust") {
    return new THREE.Vector3(1, 0.35, 0.25).normalize();
  }
  if (id === "incline_barbell_bench_press") {
    return new THREE.Vector3(0.05, 0.55, 0.85).normalize();
  }
  if (
    id === "barbell_bench_press" ||
    id === "skull_crusher"
  ) {
    return new THREE.Vector3(0.82, 0.2, 0.62).normalize();
  }
  const sideBiased = sideViewExercises.has(id);
  return new THREE.Vector3(
    sideBiased ? 1 : 0.68,
    sideBiased ? 0.2 : 0.24,
    sideBiased ? 0.32 : 1,
  ).normalize();
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

function initialBodyStyle(): BodyStyle {
  const requested = query.get("body");
  if (isBodyStyle(requested)) return requested;
  try {
    const stored = window.localStorage.getItem("noop.strength.trainer.body");
    if (isBodyStyle(stored)) return stored;
  } catch {
    // Local file viewers can deny storage; the selector still works for the session.
  }
  return "man";
}

function storeBodyStyle(style: BodyStyle): void {
  try {
    window.localStorage.setItem("noop.strength.trainer.body", style);
  } catch {
    // Storage is optional in native offline web views.
  }
}

function isBodyStyle(value: string | null | undefined): value is BodyStyle {
  return value === "man" || value === "woman";
}

function updateBodyStyleButtons(enabled: boolean): void {
  for (const button of bodyStyleButtons) {
    const selected = button.dataset.bodyStyle === bodyStyle;
    button.ariaPressed = String(selected);
    button.disabled = !enabled || selected;
  }
}

function required<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element as T;
}

class ExerciseEquipment {
  readonly root = new THREE.Group();
  private readonly dynamicKind: DynamicEquipment;
  private readonly dynamic: THREE.Group | undefined;
  private readonly bandSegments: THREE.Mesh[] = [];
  private readonly cableSegments: THREE.Mesh[] = [];
  private readonly leftHand: THREE.Object3D | undefined;
  private readonly rightHand: THREE.Object3D | undefined;
  private readonly leftPalm: THREE.Object3D | undefined;
  private readonly rightPalm: THREE.Object3D | undefined;
  private readonly leftFoot: THREE.Object3D | undefined;
  private readonly rightFoot: THREE.Object3D | undefined;
  private readonly leftKnee: THREE.Object3D | undefined;
  private readonly rightKnee: THREE.Object3D | undefined;
  private readonly hips: THREE.Object3D | undefined;
  private readonly pullUpFrame: THREE.Group | undefined;
  private readonly dipFrame: THREE.Group | undefined;
  private readonly abWheel: THREE.Group | undefined;
  private readonly cableHandle: THREE.Group | undefined;
  private readonly cableLeftHandle: THREE.Group | undefined;
  private readonly cableRightHandle: THREE.Group | undefined;
  private readonly footPlate: THREE.Mesh | undefined;
  private readonly ankleRoller: THREE.Mesh | undefined;
  private readonly thighPad: THREE.Mesh | undefined;
  private readonly rearFootBench: THREE.Mesh | undefined;
  private readonly rowBench: THREE.Group | undefined;
  private readonly leftMachineHandle: THREE.Mesh | undefined;
  private readonly rightMachineHandle: THREE.Mesh | undefined;
  private readonly cycleSeat: THREE.Mesh | undefined;
  private readonly cycleHandlebar: THREE.Group | undefined;
  private readonly cycleStem: THREE.Mesh | undefined;
  private readonly leftPedal: THREE.Mesh | undefined;
  private readonly rightPedal: THREE.Mesh | undefined;
  private readonly rowerSeat: THREE.Mesh | undefined;
  private readonly rowerHandle: THREE.Group | undefined;
  private readonly rowerCable: THREE.Mesh | undefined;
  private readonly calfPlatform: THREE.Mesh | undefined;
  private readonly leftPosition = new THREE.Vector3();
  private readonly rightPosition = new THREE.Vector3();
  private readonly hipsPosition = new THREE.Vector3();
  private readonly leftFootPosition = new THREE.Vector3();
  private readonly rightFootPosition = new THREE.Vector3();
  private readonly leftKneePosition = new THREE.Vector3();
  private readonly rightKneePosition = new THREE.Vector3();
  private readonly midpoint = new THREE.Vector3();
  private readonly leftPalmPosition = new THREE.Vector3();
  private readonly rightPalmPosition = new THREE.Vector3();
  private readonly palmOffset = new THREE.Vector3();

  constructor(scene: THREE.Scene, model: THREE.Object3D, private readonly id: string) {
    scene.add(this.root);
    this.leftHand = findBone(model, "lefthand");
    this.rightHand = findBone(model, "righthand");
    this.leftPalm = findBone(model, "lefthandmiddle1");
    this.rightPalm = findBone(model, "righthandmiddle1");
    this.leftFoot = findBone(model, "leftfoot");
    this.rightFoot = findBone(model, "rightfoot");
    this.leftKnee = findBone(model, "leftleg");
    this.rightKnee = findBone(model, "rightleg");
    this.hips = findBone(model, "hips");
    this.dynamicKind = dynamicEquipment(id);

    if (this.dynamicKind === "barbell") {
      const plateRadius = id === "incline_barbell_bench_press"
        ? 0.06
        : id === "barbell_hip_thrust"
        ? 0.08
        : compactBarbellExercises.has(id)
          ? 0.09
          : 0.145;
      this.dynamic = makeBarbell(plateRadius);
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "dumbbells") {
      this.dynamic = new THREE.Group();
      this.dynamic.add(makeDumbbell(), makeDumbbell());
      this.root.add(this.dynamic);
    } else if (
      this.dynamicKind === "singleDumbbell" ||
      this.dynamicKind === "centerDumbbell"
    ) {
      this.dynamic = makeDumbbell();
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "kettlebell") {
      this.dynamic = makeKettlebell();
      this.root.add(this.dynamic);
    } else if (this.dynamicKind === "band") {
      const segmentCount = id === "resistance_band_row" ? 2 : 1;
      for (let index = 0; index < segmentCount; index += 1) {
        const segment = makeCableSegment(0.009);
        this.bandSegments.push(segment);
        this.root.add(segment);
      }
    }
    addStructuralEquipment(this.root, id);
    addCableAttachments(this.root, id);
    this.pullUpFrame = this.root.getObjectByName("PullUpFrame") as THREE.Group | undefined;
    this.dipFrame = this.root.getObjectByName("DipFrame") as THREE.Group | undefined;
    this.abWheel = this.root.getObjectByName("AbWheel") as THREE.Group | undefined;
    this.cableHandle = this.root.getObjectByName("CableHandle") as THREE.Group | undefined;
    this.cableLeftHandle = this.root.getObjectByName("CableLeftHandle") as THREE.Group | undefined;
    this.cableRightHandle = this.root.getObjectByName("CableRightHandle") as THREE.Group | undefined;
    this.footPlate = this.root.getObjectByName("FootPlate") as THREE.Mesh | undefined;
    this.ankleRoller = this.root.getObjectByName("AnkleRoller") as THREE.Mesh | undefined;
    this.thighPad = this.root.getObjectByName("ThighPad") as THREE.Mesh | undefined;
    this.rearFootBench = this.root.getObjectByName("RearFootBench") as THREE.Mesh | undefined;
    this.rowBench = this.root.getObjectByName("RowBench") as THREE.Group | undefined;
    this.leftMachineHandle = this.root.getObjectByName("LeftMachineHandle") as THREE.Mesh | undefined;
    this.rightMachineHandle = this.root.getObjectByName("RightMachineHandle") as THREE.Mesh | undefined;
    this.cycleSeat = this.root.getObjectByName("CycleSeat") as THREE.Mesh | undefined;
    this.cycleHandlebar = this.root.getObjectByName("CycleHandlebar") as THREE.Group | undefined;
    this.cycleStem = this.root.getObjectByName("CycleStem") as THREE.Mesh | undefined;
    this.leftPedal = this.root.getObjectByName("LeftPedal") as THREE.Mesh | undefined;
    this.rightPedal = this.root.getObjectByName("RightPedal") as THREE.Mesh | undefined;
    this.rowerSeat = this.root.getObjectByName("RowerSeat") as THREE.Mesh | undefined;
    this.rowerHandle = this.root.getObjectByName("RowerHandle") as THREE.Group | undefined;
    this.rowerCable = this.root.getObjectByName("RowerCable") as THREE.Mesh | undefined;
    this.calfPlatform = this.root.getObjectByName("CalfPlatform") as THREE.Mesh | undefined;
    this.root.traverse((object) => {
      if (object instanceof THREE.Mesh && object.name.startsWith("CableSegment")) {
        this.cableSegments.push(object);
      }
    });
  }

  update(): void {
    this.leftHand?.getWorldPosition(this.leftPosition);
    this.rightHand?.getWorldPosition(this.rightPosition);
    if (this.leftPalm) {
      this.leftPalm.getWorldPosition(this.leftPalmPosition);
    }
    if (this.rightPalm) {
      this.rightPalm.getWorldPosition(this.rightPalmPosition);
    }
    if (this.leftPalm && this.rightPalm && this.dynamicKind === "barbell") {
      this.palmOffset
        .copy(this.leftPalmPosition)
        .add(this.rightPalmPosition)
        .sub(this.leftPosition)
        .sub(this.rightPosition)
        .multiplyScalar(0.29);
      this.leftPosition.add(this.palmOffset);
      this.rightPosition.add(this.palmOffset);
    } else {
      if (this.leftPalm) this.leftPosition.lerp(this.leftPalmPosition, 0.58);
      if (this.rightPalm) this.rightPosition.lerp(this.rightPalmPosition, 0.58);
    }
    this.hips?.getWorldPosition(this.hipsPosition);
    this.leftFoot?.getWorldPosition(this.leftFootPosition);
    this.rightFoot?.getWorldPosition(this.rightFootPosition);
    this.leftKnee?.getWorldPosition(this.leftKneePosition);
    this.rightKnee?.getWorldPosition(this.rightKneePosition);
    if (this.pullUpFrame && this.leftHand && this.rightHand) {
      this.pullUpFrame.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
      this.pullUpFrame.position.y -= 0.045;
    }
    if (this.dipFrame && this.leftHand && this.rightHand) {
      this.dipFrame.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
    }
    if (this.abWheel && this.leftHand && this.rightHand) {
      placeAcrossHands(this.abWheel, this.leftPosition, this.rightPosition);
    }

    if (this.dynamicKind === "barbell" && this.dynamic) {
      const hipMounted = this.id === "barbell_hip_thrust";
      if (hipMounted) {
        this.dynamic.position.copy(this.hipsPosition);
        this.dynamic.position.y += 0.04;
        this.dynamic.position.z -= 0.12;
        this.dynamic.quaternion.identity();
      } else if (this.leftHand && this.rightHand) {
        placeAcrossHands(this.dynamic, this.leftPosition, this.rightPosition);
        this.dynamic.quaternion.identity();
      }
    } else if (this.dynamicKind === "dumbbells" && this.dynamic) {
      const [left, right] = this.dynamic.children;
      left.position.copy(this.leftPosition);
      right.position.copy(this.rightPosition);
      orientDumbbell(left, this.id);
      orientDumbbell(right, this.id);
    } else if (this.dynamicKind === "singleDumbbell" && this.dynamic) {
      this.dynamic.position.copy(this.leftPosition);
      this.dynamic.rotation.set(0, Math.PI / 2, 0);
    } else if (
      this.dynamicKind === "centerDumbbell" &&
      this.dynamic &&
      this.leftHand &&
      this.rightHand
    ) {
      this.dynamic.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
      this.dynamic.rotation.z = Math.PI / 2;
    } else if (
      this.dynamicKind === "kettlebell" &&
      this.dynamic &&
      this.leftHand &&
      this.rightHand
    ) {
      this.dynamic.position.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
      this.dynamic.position.y -= 0.13;
    } else if (this.bandSegments.length > 0 && this.leftHand && this.rightHand) {
      if (this.id === "resistance_band_row") {
        const anchor = this.midpoint.set(0, 1.22, 0.92);
        placeBetween(this.bandSegments[0], anchor, this.leftPosition);
        placeBetween(this.bandSegments[1], anchor, this.rightPosition);
      } else {
        placeBetween(this.bandSegments[0], this.leftPosition, this.rightPosition);
      }
    }
    this.updateCableAttachments();
    this.updateMachineContact();
  }

  dispose(): void {
    this.root.removeFromParent();
    this.root.traverse((object) => {
      if (object instanceof THREE.Mesh || object instanceof THREE.Line) {
        object.geometry.dispose();
      }
    });
  }

  private updateCableAttachments(): void {
    if (this.cableSegments.length === 0) return;
    const center = this.midpoint.copy(this.leftPosition).lerp(this.rightPosition, 0.5);
    if (this.cableHandle) placeAcrossHands(this.cableHandle, this.leftPosition, this.rightPosition);
    this.cableLeftHandle?.position.copy(this.leftPosition);
    this.cableRightHandle?.position.copy(this.rightPosition);
    if (this.id === "cable_crossover") {
      placeBetween(
        this.cableSegments[0],
        new THREE.Vector3(0.72, 1.72, -0.58),
        this.leftPosition,
      );
      placeBetween(
        this.cableSegments[1],
        new THREE.Vector3(-0.72, 1.72, -0.58),
        this.rightPosition,
      );
      return;
    }
    if (this.id === "face_pull" || this.id === "cable_crunch") {
      const anchor = this.id === "face_pull"
        ? new THREE.Vector3(0, 1.56, -0.58)
        : new THREE.Vector3(0, 1.82, -0.58);
      placeBetween(this.cableSegments[0], anchor, this.leftPosition);
      placeBetween(this.cableSegments[1], anchor, this.rightPosition);
      return;
    }
    const anchor = this.id === "seated_cable_row"
      ? new THREE.Vector3(0, 0.42, 0.92)
      : new THREE.Vector3(0, 1.84, -0.58);
    placeBetween(this.cableSegments[0], anchor, center);
  }

  private updateMachineContact(): void {
    const feet = this.midpoint
      .copy(this.leftFootPosition)
      .lerp(this.rightFootPosition, 0.5);
    if (this.footPlate) {
      this.footPlate.position.copy(feet);
      this.footPlate.position.z += 0.08;
    }
    if (this.ankleRoller) {
      this.ankleRoller.position.copy(feet);
      this.ankleRoller.position.y += 0.05;
    }
    if (this.thighPad) {
      this.thighPad.position
        .copy(this.leftKneePosition)
        .lerp(this.rightKneePosition, 0.5);
      this.thighPad.position.y -= 0.08;
    }
    if (this.rearFootBench) {
      this.rearFootBench.position.copy(this.rightFootPosition);
      this.rearFootBench.position.y -= 0.11;
    }
    if (this.rowBench) {
      this.rowBench.position
        .copy(this.rightPosition)
        .lerp(this.rightKneePosition, 0.5);
      this.rowBench.position.y =
        Math.min(this.rightPosition.y, this.rightKneePosition.y) - 0.045;
    }
    this.leftMachineHandle?.position.copy(this.leftPosition);
    this.rightMachineHandle?.position.copy(this.rightPosition);
    if (this.cycleSeat) {
      this.cycleSeat.position.copy(this.hipsPosition);
      this.cycleSeat.position.y -= 0.08;
    }
    if (this.cycleHandlebar) {
      placeAcrossHands(this.cycleHandlebar, this.leftPosition, this.rightPosition);
    }
    if (this.cycleStem) {
      placeBetween(
        this.cycleStem,
        this.midpoint.set(0, 0.68, 0.48),
        this.leftPosition.clone().lerp(this.rightPosition, 0.5),
      );
    }
    if (this.leftPedal) this.leftPedal.position.copy(this.leftFootPosition);
    if (this.rightPedal) this.rightPedal.position.copy(this.rightFootPosition);
    if (this.rowerSeat) {
      this.rowerSeat.position.copy(this.hipsPosition);
      this.rowerSeat.position.y -= 0.11;
    }
    if (this.rowerHandle) {
      placeAcrossHands(this.rowerHandle, this.leftPosition, this.rightPosition);
    }
    if (this.rowerCable) {
      placeBetween(
        this.rowerCable,
        this.midpoint.set(0, 0.48, 0.92),
        this.leftPosition.clone().lerp(this.rightPosition, 0.5),
      );
    }
    if (this.calfPlatform) {
      this.calfPlatform.position.copy(feet);
      this.calfPlatform.position.y -= 0.065;
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

function makeBarbell(plateRadius = 0.145): THREE.Group {
  const group = new THREE.Group();
  group.add(cylinder(0.016, 1.58, graphite, "x"));
  for (const direction of [-1, 1]) {
    const plate = cylinder(plateRadius, 0.055, rubber, "x");
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
  group.add(cylinder(0.015, 0.28, graphite, "x"));
  for (const direction of [-1, 1]) {
    const plate = cylinder(0.076, 0.06, rubber, "x");
    plate.position.x = direction * 0.105;
    group.add(plate);
    const cap = cylinder(0.057, 0.011, red, "x");
    cap.position.x = direction * 0.14;
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

function makeCableSegment(radius = 0.006): THREE.Mesh {
  const segment = new THREE.Mesh(
    new THREE.CylinderGeometry(radius, radius, 1, 10),
    red,
  );
  segment.castShadow = true;
  return segment;
}

function makeHandle(length: number, name: string): THREE.Group {
  const handle = new THREE.Group();
  handle.name = name;
  handle.add(cylinder(0.018, length, graphite, "x"));
  markShadows(handle);
  return handle;
}

function addCableAttachments(root: THREE.Group, id: string): void {
  if (!cableExercises.has(id)) return;
  const segmentCount = ["cable_crossover", "face_pull", "cable_crunch"].includes(id)
    ? 2
    : 1;
  for (let index = 0; index < segmentCount; index += 1) {
    const segment = makeCableSegment();
    segment.name = `CableSegment${index + 1}`;
    root.add(segment);
  }
  if (id === "cable_crossover" || id === "face_pull" || id === "cable_crunch") {
    const left = makeHandle(0.16, "CableLeftHandle");
    const right = makeHandle(0.16, "CableRightHandle");
    left.rotation.z = Math.PI / 2;
    right.rotation.z = Math.PI / 2;
    root.add(left, right);
  } else {
    const length = id === "lat_pulldown" ? 1.12 : id === "triceps_pushdown" ? 0.46 : 0.42;
    root.add(makeHandle(length, "CableHandle"));
  }
}

function addStructuralEquipment(root: THREE.Group, id: string): void {
  if (id === "barbell_hip_thrust") {
    addHipThrustBench(root);
  } else if (benchExercises.has(id)) {
    addBench(root, id.includes("incline"));
  }
  if (id === "one_arm_dumbbell_row") addRowBench(root);
  if (id === "chest_supported_row") addChestSupportedBench(root);
  if (id === "preacher_curl") addPreacherBench(root);
  if (barExercises.has(id)) addPullUpBar(root);
  if (id === "parallel_bar_dip") addDipBars(root);
  if (id === "ab_wheel_rollout") addAbWheel(root);
  if (id === "bulgarian_split_squat") addRearFootBench(root);
  if (id === "standing_calf_raise") addCalfPlatform(root);
  if (id === "glute_bridge") addExerciseMat(root);
  if (id === "back_extension") addBackExtensionBench(root);
  if (id === "resistance_band_row") addBandAnchor(root);
  if (cableExercises.has(id)) addCableTower(root, id);
  if (machineExercises.has(id)) addMachineFrame(root, id);
  if (id === "treadmill_run") addTreadmill(root);
  if (id === "indoor_cycling") addCycle(root);
  if (id === "rowing_ergometer") addRower(root);
  if (id === "stair_climber") addStairs(root);
  markShadows(root);
}

function addHipThrustBench(root: THREE.Group): void {
  const pad = new THREE.Mesh(
    new THREE.BoxGeometry(0.72, 0.12, 0.44),
    rubber,
  );
  pad.position.set(0, 0.3, -0.48);
  root.add(pad);
  for (const x of [-0.27, 0.27]) {
    const post = new THREE.Mesh(
      new THREE.BoxGeometry(0.06, 0.28, 0.06),
      graphite,
    );
    post.position.set(x, 0.14, -0.48);
    root.add(post);
  }
  const base = new THREE.Mesh(
    new THREE.BoxGeometry(0.82, 0.05, 0.34),
    graphite,
  );
  base.position.set(0, 0.025, -0.48);
  root.add(base);
}

function addBench(root: THREE.Group, inclined: boolean): void {
  const bench = new THREE.Group();
  if (inclined) {
    const backPad = new THREE.Mesh(
      new THREE.BoxGeometry(0.56, 0.075, 1.15),
      rubber,
    );
    backPad.rotation.x = 0.61;
    backPad.position.set(0, 0.73, -0.02);
    bench.add(backPad);

    const seatPad = new THREE.Mesh(
      new THREE.BoxGeometry(0.56, 0.075, 0.44),
      rubber,
    );
    seatPad.position.set(0, 0.39, 0.4);
    bench.add(seatPad);

    const support = new THREE.Mesh(
      new THREE.BoxGeometry(0.065, 0.62, 0.065),
      graphite,
    );
    support.position.set(0, 0.31, 0.02);
    bench.add(support);
    for (const z of [-0.22, 0.46]) {
      const foot = new THREE.Mesh(
        new THREE.BoxGeometry(0.5, 0.05, 0.1),
        graphite,
      );
      foot.position.set(0, 0.025, z);
      bench.add(foot);
    }
    root.add(bench);
    return;
  }

  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.11, 1.35), rubber);
  pad.position.set(0, 0.2, 0.08);
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

function addDipBars(root: THREE.Group): void {
  const frame = new THREE.Group();
  frame.name = "DipFrame";
  for (const x of [-0.31, 0.31]) {
    const bar = cylinder(0.025, 0.92, graphite, "y");
    bar.rotation.x = Math.PI / 2;
    bar.position.x = x;
    frame.add(bar);
    const upright = cylinder(0.027, 1.05, graphite, "y");
    upright.position.set(x, -0.53, 0.3);
    frame.add(upright);
    const foot = new THREE.Mesh(new THREE.BoxGeometry(0.14, 0.045, 0.72), graphite);
    foot.position.set(x, -1.04, 0.3);
    frame.add(foot);
  }
  root.add(frame);
}

function addAbWheel(root: THREE.Group): void {
  const wheel = new THREE.Group();
  wheel.name = "AbWheel";
  const tire = cylinder(0.135, 0.09, rubber, "x");
  wheel.add(tire);
  wheel.add(cylinder(0.018, 0.52, graphite, "x"));
  for (const x of [-0.19, 0.19]) {
    const grip = cylinder(0.032, 0.14, red, "x");
    grip.position.x = x;
    wheel.add(grip);
  }
  root.add(wheel);
}

function addRowBench(root: THREE.Group): void {
  const bench = new THREE.Group();
  bench.name = "RowBench";
  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.54, 0.09, 0.96), rubber);
  bench.add(pad);
  for (const z of [-0.2, 0.4]) {
    const post = new THREE.Mesh(new THREE.BoxGeometry(0.055, 0.5, 0.055), graphite);
    post.position.set(0, -0.25, z);
    bench.add(post);
  }
  root.add(bench);
}

function addChestSupportedBench(root: THREE.Group): void {
  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.46, 0.09, 0.9), rubber);
  pad.rotation.x = -0.68;
  pad.position.set(0, 0.76, 0.1);
  root.add(pad);
  const post = cylinder(0.032, 0.74, graphite, "y");
  post.position.set(0, 0.37, -0.08);
  root.add(post);
  const base = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.055, 0.52), graphite);
  base.position.set(0, 0.03, -0.08);
  root.add(base);
}

function addPreacherBench(root: THREE.Group): void {
  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.085, 0.38), rubber);
  pad.rotation.x = 0.64;
  pad.position.set(0, 1.16, 0.32);
  root.add(pad);
  const post = cylinder(0.032, 0.98, graphite, "y");
  post.position.set(0, 0.57, 0.14);
  root.add(post);
  const base = new THREE.Mesh(new THREE.BoxGeometry(0.65, 0.06, 0.5), graphite);
  base.position.set(0, 0.03, 0.12);
  root.add(base);
}

function addCableTower(root: THREE.Group, id: string): void {
  const z = id === "seated_cable_row" ? 0.92 : -0.58;
  for (const x of [-0.72, 0.72]) {
    const tower = new THREE.Mesh(new THREE.BoxGeometry(0.09, 1.9, 0.12), graphite);
    tower.position.set(x, 0.95, z);
    root.add(tower);
  }
  const crossbar = new THREE.Mesh(new THREE.BoxGeometry(1.53, 0.08, 0.1), graphite);
  crossbar.position.set(0, 1.88, z);
  root.add(crossbar);
}

function addBackExtensionBench(root: THREE.Group): void {
  for (const x of [-0.18, 0.18]) {
    const hipPad = cylinder(0.085, 0.3, rubber, "x");
    hipPad.position.set(x, 0.68, 0.02);
    root.add(hipPad);
  }
  const upright = cylinder(0.032, 0.68, graphite, "y");
  upright.position.set(0, 0.34, -0.02);
  root.add(upright);
  const ankleRoll = cylinder(0.065, 0.62, rubber, "x");
  ankleRoll.position.set(0, 0.46, -0.72);
  root.add(ankleRoll);
  const brace = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.055, 0.86), graphite);
  brace.position.set(0, 0.24, -0.36);
  root.add(brace);
}

function addBandAnchor(root: THREE.Group): void {
  const post = cylinder(0.025, 1.55, graphite, "y");
  post.position.set(0, 0.78, 0.92);
  root.add(post);
  const base = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.055, 0.38), graphite);
  base.position.set(0, 0.028, 0.92);
  root.add(base);
  const eye = new THREE.Mesh(new THREE.TorusGeometry(0.055, 0.012, 10, 24), red);
  eye.position.set(0, 1.22, 0.89);
  eye.rotation.x = Math.PI / 2;
  root.add(eye);
}

function addMachineFrame(root: THREE.Group, id: string): void {
  if (id === "hack_squat") {
    const frame = new THREE.Group();
    const base = new THREE.Mesh(new THREE.BoxGeometry(0.94, 0.065, 1.12), graphite);
    base.position.set(0, 0.033, -0.05);
    frame.add(base);
    const back = new THREE.Mesh(new THREE.BoxGeometry(0.55, 1.18, 0.09), rubber);
    back.position.set(0, 0.82, -0.43);
    back.rotation.x = -0.2;
    frame.add(back);
    for (const x of [-0.43, 0.43]) {
      const rail = cylinder(0.027, 1.72, graphite, "y");
      rail.position.set(x, 0.86, -0.46);
      rail.rotation.x = -0.2;
      frame.add(rail);
    }
    const plate = new THREE.Mesh(new THREE.BoxGeometry(0.72, 0.58, 0.065), graphite);
    plate.name = "FootPlate";
    plate.rotation.x = -0.42;
    frame.add(plate);
    for (const [name, x] of [
      ["LeftMachineHandle", -0.38],
      ["RightMachineHandle", 0.38],
    ] as const) {
      const handle = cylinder(0.022, 0.26, graphite, "y");
      handle.name = name;
      handle.rotation.x = Math.PI / 2;
      handle.position.set(x, 1.02, -0.28);
      frame.add(handle);
    }
    root.add(frame);
    return;
  }
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
  if (id === "leg_press" || id === "hack_squat") {
    const plate = new THREE.Mesh(new THREE.BoxGeometry(0.72, 0.64, 0.065), graphite);
    plate.name = "FootPlate";
    plate.rotation.x = -0.5;
    frame.add(plate);
  }
  if (id === "leg_extension" || id === "lying_leg_curl") {
    const roller = cylinder(0.065, 0.72, rubber, "x");
    roller.name = "AnkleRoller";
    frame.add(roller);
  }
  if (id === "seated_calf_raise") {
    const pad = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.09, 0.26), rubber);
    pad.name = "ThighPad";
    frame.add(pad);
  }
  if (id === "machine_chest_press") {
    for (const [name, x] of [["LeftMachineHandle", -0.2], ["RightMachineHandle", 0.2]] as const) {
      const handle = cylinder(0.022, 0.24, graphite, "y");
      handle.name = name;
      handle.rotation.x = Math.PI / 2;
      handle.position.x = x;
      frame.add(handle);
    }
  }
  root.add(frame);
}

function addRearFootBench(root: THREE.Group): void {
  const pad = new THREE.Mesh(new THREE.BoxGeometry(0.56, 0.19, 0.5), rubber);
  pad.name = "RearFootBench";
  root.add(pad);
}

function addCalfPlatform(root: THREE.Group): void {
  const platform = new THREE.Mesh(new THREE.BoxGeometry(0.72, 0.11, 0.38), graphite);
  platform.name = "CalfPlatform";
  platform.position.set(0, 0.045, 0.06);
  root.add(platform);
}

function addExerciseMat(root: THREE.Group): void {
  const mat = new THREE.Mesh(new THREE.BoxGeometry(0.86, 0.025, 1.88), rubber);
  mat.position.y = 0.012;
  root.add(mat);
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
  wheel.position.set(0, 0.46, 0.42);
  root.add(wheel);
  const post = cylinder(0.035, 0.78, graphite, "y");
  post.position.set(0, 0.68, 0.1);
  post.rotation.z = -0.2;
  root.add(post);
  const seat = new THREE.Mesh(new THREE.BoxGeometry(0.36, 0.06, 0.18), rubber);
  seat.name = "CycleSeat";
  seat.position.set(0, 1.02, -0.1);
  root.add(seat);
  const handlePost = cylinder(0.028, 0.78, graphite, "y");
  handlePost.rotation.x = -0.42;
  handlePost.position.set(0, 0.72, 0.48);
  root.add(handlePost);
  const handlebar = makeHandle(0.72, "CycleHandlebar");
  handlebar.position.set(0, 1.12, 0.72);
  root.add(handlebar);
  const stem = makeCableSegment(0.018);
  stem.name = "CycleStem";
  stem.material = graphite;
  root.add(stem);
  const crank = cylinder(0.025, 0.38, red, "x");
  crank.position.set(0, 0.46, 0.42);
  root.add(crank);
  for (const [name, x] of [["LeftPedal", -0.17], ["RightPedal", 0.17]] as const) {
    const pedal = new THREE.Mesh(new THREE.BoxGeometry(0.13, 0.035, 0.27), graphite);
    pedal.name = name;
    pedal.position.set(x, 0.46, 0.1);
    root.add(pedal);
  }
}

function addRower(root: THREE.Group): void {
  const rail = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.08, 1.9), graphite);
  rail.position.set(0, 0.24, 0.08);
  root.add(rail);
  const seat = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.08, 0.34), rubber);
  seat.name = "RowerSeat";
  seat.position.set(0, 0.34, 0.12);
  root.add(seat);
  const flywheel = new THREE.Mesh(new THREE.CylinderGeometry(0.32, 0.32, 0.22, 36), rubber);
  flywheel.rotation.z = Math.PI / 2;
  flywheel.position.set(0, 0.38, 0.92);
  root.add(flywheel);
  const hub = cylinder(0.055, 0.24, red, "x");
  hub.position.set(0, 0.38, 0.92);
  root.add(hub);
  for (const x of [-0.16, 0.16]) {
    const footplate = new THREE.Mesh(new THREE.BoxGeometry(0.14, 0.035, 0.3), graphite);
    footplate.position.set(x, 0.14, 0.72);
    footplate.rotation.x = -0.2;
    root.add(footplate);
  }
  const cable = makeCableSegment(0.004);
  cable.name = "RowerCable";
  root.add(cable);
  const handle = makeHandle(0.5, "RowerHandle");
  for (const x of [-0.19, 0.19]) {
    const grip = cylinder(0.027, 0.1, red, "x");
    grip.position.x = x;
    handle.add(grip);
  }
  root.add(handle);
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

function placeBetween(
  object: THREE.Object3D,
  first: THREE.Vector3,
  second: THREE.Vector3,
): void {
  const direction = second.clone().sub(first);
  const length = direction.length();
  object.position.copy(first).lerp(second, 0.5);
  object.scale.set(1, Math.max(0.001, length), 1);
  if (length > 0.0001) {
    object.quaternion.setFromUnitVectors(
      new THREE.Vector3(0, 1, 0),
      direction.normalize(),
    );
  }
}

function findBone(root: THREE.Object3D, normalizedName: string): THREE.Object3D | undefined {
  let match: THREE.Object3D | undefined;
  root.traverse((object) => {
    const normalized = object.name.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (!match && normalized.endsWith(normalizedName)) match = object;
  });
  return match;
}

function dynamicEquipment(id: string): DynamicEquipment {
  if (id === "one_arm_dumbbell_row") return "singleDumbbell";
  if (id === "overhead_triceps_extension") return "centerDumbbell";
  if (barbellExercises.has(id)) return "barbell";
  if (dumbbellExercises.has(id)) return "dumbbells";
  if (kettlebellExercises.has(id)) return "kettlebell";
  if (bandExercises.has(id)) return "band";
  return "none";
}

function orientDumbbell(object: THREE.Object3D, id: string): void {
  object.rotation.set(0, 0, 0);
  if (id === "hammer_curl") {
    object.rotation.z = Math.PI / 2;
  } else if (neutralGripDumbbellExercises.has(id)) {
    object.rotation.y = Math.PI / 2;
  }
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
const compactBarbellExercises = new Set([
  "barbell_bench_press",
  "incline_barbell_bench_press",
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
  "chest_supported_row",
  "dumbbell_shoulder_press",
  "lateral_raise",
  "rear_delt_fly",
  "farmers_carry",
]);
const neutralGripDumbbellExercises = new Set([
  "dumbbell_lunge",
  "walking_lunge",
  "bulgarian_split_squat",
  "dumbbell_bench_press",
  "chest_fly",
  "chest_supported_row",
  "dumbbell_shoulder_press",
  "lateral_raise",
  "rear_delt_fly",
  "farmers_carry",
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
  "lying_leg_curl",
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
const sideViewExercises = new Set([
  "barbell_bench_press",
  "incline_barbell_bench_press",
  "dumbbell_bench_press",
  "chest_fly",
  "skull_crusher",
  "plank",
  "push_up",
  "glute_bridge",
  "lying_leg_curl",
  "leg_press",
  "side_plank",
  "ab_wheel_rollout",
  "back_extension",
  "seated_cable_row",
  "indoor_cycling",
  "rowing_ergometer",
  "stair_climber",
  "treadmill_run",
  "overhead_triceps_extension",
  "resistance_band_row",
]);
