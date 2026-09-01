import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";
import { ExerciseMannequin } from "./mannequin";

const MODEL_SCALE = 0.93;
const UP = new THREE.Vector3(0, 1, 0);
const FORWARD = new THREE.Vector3(0, 0, 1);

interface BoneLink {
  bone: THREE.Object3D;
  child: THREE.Object3D;
  restQuaternion: THREE.Quaternion;
  restDirection: THREE.Vector3;
}

interface FingerJoint {
  bone: THREE.Object3D;
  restQuaternion: THREE.Quaternion;
  curl: number;
}

interface TargetRig {
  root: THREE.Object3D;
  hips: THREE.Object3D;
  spine: THREE.Object3D;
  chest: THREE.Object3D;
  neck: THREE.Object3D;
  leftShoulder: THREE.Object3D;
  leftElbow: THREE.Object3D;
  leftHand: THREE.Object3D;
  rightShoulder: THREE.Object3D;
  rightElbow: THREE.Object3D;
  rightHand: THREE.Object3D;
  leftHip: THREE.Object3D;
  leftKnee: THREE.Object3D;
  leftFoot: THREE.Object3D;
  rightHip: THREE.Object3D;
  rightKnee: THREE.Object3D;
  rightFoot: THREE.Object3D;
}

/**
 * Smooth skinned presentation driven by the deterministic procedural motion rig.
 * The source remains the single motion authority; only joint directions are
 * transferred, so the imported model keeps its original bind pose and weights.
 */
export class ExerciseHumanoid {
  readonly root: THREE.Group;

  private readonly target: TargetRig;
  private readonly hips: THREE.Object3D;
  private readonly links: Record<string, BoneLink>;
  private readonly fingers: FingerJoint[];
  private readonly grip: number;
  private readonly rootRestQuaternion: THREE.Quaternion;
  private readonly rootRestScale: THREE.Vector3;
  private readonly sourcePosition = new THREE.Vector3();
  private readonly modelPosition = new THREE.Vector3();
  private readonly firstPosition = new THREE.Vector3();
  private readonly secondPosition = new THREE.Vector3();
  private readonly direction = new THREE.Vector3();
  private readonly parentQuaternion = new THREE.Quaternion();
  private readonly desiredLocal = new THREE.Vector3();
  private readonly swing = new THREE.Quaternion();
  private readonly fingerRotation = new THREE.Quaternion();
  private readonly sourceQuaternion = new THREE.Quaternion();

  static async load(
    modelURL: string,
    source: ExerciseMannequin,
    exerciseId: string,
  ): Promise<ExerciseHumanoid> {
    const gltf = await new GLTFLoader().loadAsync(modelURL);
    return new ExerciseHumanoid(gltf.scene, source, exerciseId);
  }

  private constructor(
    model: THREE.Group,
    source: ExerciseMannequin,
    exerciseId: string,
  ) {
    this.root = model;
    this.root.name = "ExerciseHumanoid";
    this.rootRestQuaternion = model.quaternion.clone();
    this.rootRestScale = model.scale.clone().multiplyScalar(MODEL_SCALE);
    this.root.scale.copy(this.rootRestScale);
    this.target = targetRig(source.root);
    this.hips = requiredNode(model, "hips");
    this.links = {
      spine: boneLink(model, "spine", "spine1"),
      spine1: boneLink(model, "spine1", "spine2"),
      spine2: boneLink(model, "spine2", "neck"),
      neck: boneLink(model, "neck", "head"),
      leftShoulder: boneLink(model, "leftshoulder", "leftarm"),
      leftArm: boneLink(model, "leftarm", "leftforearm"),
      leftForeArm: boneLink(model, "leftforearm", "lefthand"),
      rightShoulder: boneLink(model, "rightshoulder", "rightarm"),
      rightArm: boneLink(model, "rightarm", "rightforearm"),
      rightForeArm: boneLink(model, "rightforearm", "righthand"),
      leftUpLeg: boneLink(model, "leftupleg", "leftleg"),
      leftLeg: boneLink(model, "leftleg", "leftfoot"),
      leftFoot: boneLink(model, "leftfoot", "lefttoebase"),
      rightUpLeg: boneLink(model, "rightupleg", "rightleg"),
      rightLeg: boneLink(model, "rightleg", "rightfoot"),
      rightFoot: boneLink(model, "rightfoot", "righttoebase"),
    };
    this.fingers = fingerJoints(model);
    this.grip = gripAmount(exerciseId);
    styleModel(model);
    this.update();
  }

  update(): void {
    this.resetPose();
    this.alignRoot();

    this.point(this.links.spine, this.between(this.target.hips, this.target.spine));
    this.point(this.links.spine1, this.between(this.target.spine, this.target.chest));
    this.point(this.links.spine2, this.between(this.target.chest, this.target.neck));
    this.point(this.links.neck, this.axis(this.target.neck, UP));

    this.target.leftShoulder.getWorldPosition(this.firstPosition);
    this.target.rightShoulder.getWorldPosition(this.secondPosition);
    this.modelPosition.copy(this.firstPosition).lerp(this.secondPosition, 0.5);
    this.point(
      this.links.leftShoulder,
      this.direction.copy(this.firstPosition).sub(this.modelPosition).normalize(),
    );
    this.point(
      this.links.rightShoulder,
      this.direction.copy(this.secondPosition).sub(this.modelPosition).normalize(),
    );
    this.point(
      this.links.leftArm,
      this.between(this.target.leftShoulder, this.target.leftElbow),
    );
    this.point(
      this.links.leftForeArm,
      this.between(this.target.leftElbow, this.target.leftHand),
    );
    this.point(
      this.links.rightArm,
      this.between(this.target.rightShoulder, this.target.rightElbow),
    );
    this.point(
      this.links.rightForeArm,
      this.between(this.target.rightElbow, this.target.rightHand),
    );

    this.point(
      this.links.leftUpLeg,
      this.between(this.target.leftHip, this.target.leftKnee),
    );
    this.point(
      this.links.leftLeg,
      this.between(this.target.leftKnee, this.target.leftFoot),
    );
    this.point(this.links.leftFoot, this.axis(this.target.leftFoot, FORWARD));
    this.point(
      this.links.rightUpLeg,
      this.between(this.target.rightHip, this.target.rightKnee),
    );
    this.point(
      this.links.rightLeg,
      this.between(this.target.rightKnee, this.target.rightFoot),
    );
    this.point(this.links.rightFoot, this.axis(this.target.rightFoot, FORWARD));
    this.root.updateMatrixWorld(true);
  }

  private resetPose(): void {
    for (const link of Object.values(this.links)) {
      link.bone.quaternion.copy(link.restQuaternion);
    }
    for (const finger of this.fingers) {
      this.fingerRotation.setFromAxisAngle(FORWARD, finger.curl * this.grip);
      finger.bone.quaternion
        .copy(finger.restQuaternion)
        .multiply(this.fingerRotation);
    }
    this.root.quaternion.copy(this.rootRestQuaternion);
    this.root.scale.copy(this.rootRestScale);
    this.root.position.set(0, 0, 0);
    this.root.updateMatrixWorld(true);
  }

  private alignRoot(): void {
    this.target.root.getWorldQuaternion(this.sourceQuaternion);
    this.root.quaternion.copy(this.sourceQuaternion).multiply(this.rootRestQuaternion);
    this.root.updateMatrixWorld(true);
    this.target.hips.getWorldPosition(this.sourcePosition);
    this.hips.getWorldPosition(this.modelPosition);
    this.root.position.add(this.sourcePosition.sub(this.modelPosition));
    this.root.updateMatrixWorld(true);
  }

  private point(link: BoneLink, desiredWorldDirection: THREE.Vector3): void {
    const parent = link.bone.parent;
    if (!parent || desiredWorldDirection.lengthSq() < 0.000001) return;
    parent.getWorldQuaternion(this.parentQuaternion);
    this.desiredLocal
      .copy(desiredWorldDirection)
      .normalize()
      .applyQuaternion(this.parentQuaternion.invert());
    this.swing.setFromUnitVectors(link.restDirection, this.desiredLocal);
    link.bone.quaternion.copy(this.swing).multiply(link.restQuaternion).normalize();
    link.bone.updateMatrix();
    link.bone.updateMatrixWorld(true);
  }

  private between(first: THREE.Object3D, second: THREE.Object3D): THREE.Vector3 {
    first.getWorldPosition(this.firstPosition);
    second.getWorldPosition(this.secondPosition);
    return this.direction
      .copy(this.secondPosition)
      .sub(this.firstPosition)
      .normalize();
  }

  private axis(node: THREE.Object3D, axis: THREE.Vector3): THREE.Vector3 {
    node.getWorldQuaternion(this.sourceQuaternion);
    return this.direction.copy(axis).applyQuaternion(this.sourceQuaternion).normalize();
  }
}

function targetRig(root: THREE.Object3D): TargetRig {
  return {
    root,
    hips: requiredNode(root, "hips"),
    spine: requiredNode(root, "spine"),
    chest: requiredNode(root, "spine2"),
    neck: requiredNode(root, "neck"),
    leftShoulder: requiredNode(root, "leftshoulder"),
    leftElbow: requiredNode(root, "leftelbow"),
    leftHand: requiredNode(root, "lefthand"),
    rightShoulder: requiredNode(root, "rightshoulder"),
    rightElbow: requiredNode(root, "rightelbow"),
    rightHand: requiredNode(root, "righthand"),
    leftHip: requiredNode(root, "lefthip"),
    leftKnee: requiredNode(root, "leftknee"),
    leftFoot: requiredNode(root, "leftfoot"),
    rightHip: requiredNode(root, "righthip"),
    rightKnee: requiredNode(root, "rightknee"),
    rightFoot: requiredNode(root, "rightfoot"),
  };
}

function boneLink(root: THREE.Object3D, boneName: string, childName: string): BoneLink {
  const bone = requiredNode(root, boneName);
  const child = requiredNode(root, childName);
  if (child.parent !== bone) {
    throw new Error(`${child.name} is not a direct child of ${bone.name}`);
  }
  const restQuaternion = bone.quaternion.clone();
  const restDirection = child.position
    .clone()
    .normalize()
    .applyQuaternion(restQuaternion);
  return { bone, child, restQuaternion, restDirection };
}

function requiredNode(root: THREE.Object3D, normalizedName: string): THREE.Object3D {
  let match: THREE.Object3D | undefined;
  root.traverse((object) => {
    const normalized = object.name.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (!match && normalized.endsWith(normalizedName)) match = object;
  });
  if (!match) throw new Error(`Missing rig node ${normalizedName}`);
  return match;
}

function styleModel(root: THREE.Object3D): void {
  const body = new THREE.MeshPhysicalMaterial({
    color: 0xe0192d,
    roughness: 0.42,
    metalness: 0.04,
    clearcoat: 0.24,
    clearcoatRoughness: 0.55,
  });
  const joints = new THREE.MeshPhysicalMaterial({
    color: 0xc11627,
    roughness: 0.47,
    metalness: 0.03,
    clearcoat: 0.16,
  });
  root.traverse((object) => {
    if (!(object instanceof THREE.Mesh)) return;
    object.material = object.name.toLowerCase().includes("joint") ? joints : body;
    object.castShadow = true;
    object.receiveShadow = true;
    object.frustumCulled = false;
  });
}

function fingerJoints(root: THREE.Object3D): FingerJoint[] {
  const joints: FingerJoint[] = [];
  for (const side of ["left", "right"] as const) {
    const direction = side === "left" ? -1 : 1;
    for (const finger of ["index", "middle", "ring", "pinky"]) {
      for (let segment = 1; segment <= 3; segment += 1) {
        const bone = requiredNode(root, `${side}hand${finger}${segment}`);
        const bend = segment === 1 ? 34 : segment === 2 ? 44 : 30;
        joints.push({
          bone,
          restQuaternion: bone.quaternion.clone(),
          curl: direction * bend * Math.PI / 180,
        });
      }
    }
  }
  return joints;
}

function gripAmount(exerciseId: string): number {
  if (openHandExercises.has(exerciseId)) return 0.08;
  if (loadedExercises.has(exerciseId)) return 0.78;
  return 0.42;
}

const openHandExercises = new Set([
  "plank",
  "push_up",
  "side_plank",
]);

const loadedExercises = new Set([
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
  "goblet_squat",
  "kettlebell_swing",
  "band_pull_apart",
  "resistance_band_row",
  "pull_up",
  "chin_up",
  "hanging_leg_raise",
]);
