import * as THREE from "three";

const DEG = Math.PI / 180;

type Side = "left" | "right";

interface ArmRig {
  shoulder: THREE.Group;
  elbow: THREE.Group;
  wrist: THREE.Group;
}

interface LegRig {
  hip: THREE.Group;
  knee: THREE.Group;
  ankle: THREE.Group;
}

const shell = new THREE.MeshPhysicalMaterial({
  color: 0xd7182a,
  roughness: 0.4,
  metalness: 0.08,
  clearcoat: 0.24,
  clearcoatRoughness: 0.62,
});
const shellDark = new THREE.MeshPhysicalMaterial({
  color: 0x8f101f,
  roughness: 0.46,
  metalness: 0.1,
  clearcoat: 0.15,
});
const joint = new THREE.MeshStandardMaterial({
  color: 0x20242b,
  roughness: 0.4,
  metalness: 0.46,
});
const visor = new THREE.MeshPhysicalMaterial({
  color: 0x080a0d,
  roughness: 0.18,
  metalness: 0.72,
  clearcoat: 0.58,
});

export class ExerciseMannequin {
  readonly root = new THREE.Group();

  private readonly pelvis = new THREE.Group();
  private readonly spine = new THREE.Group();
  private readonly chest = new THREE.Group();
  private readonly neck = new THREE.Group();
  private readonly leftArm: ArmRig;
  private readonly rightArm: ArmRig;
  private readonly leftLeg: LegRig;
  private readonly rightLeg: LegRig;

  constructor() {
    this.root.name = "ExerciseMannequin";
    this.pelvis.name = "Hips";
    this.spine.name = "Spine";
    this.chest.name = "Spine2";
    this.neck.name = "Neck";
    this.root.add(this.pelvis);

    this.buildTorso();
    this.leftArm = this.buildArm("left");
    this.rightArm = this.buildArm("right");
    this.leftLeg = this.buildLeg("left");
    this.rightLeg = this.buildLeg("right");
    this.root.traverse((node) => {
      if (node instanceof THREE.Mesh) {
        node.castShadow = true;
        node.receiveShadow = true;
      }
    });
    this.reset();
  }

  setBodyVisible(visible: boolean): void {
    this.root.traverse((node) => {
      if (node instanceof THREE.Mesh) node.visible = visible;
    });
  }

  pose(exerciseId: string, phase: number): void {
    this.reset();
    const amount = repAmount(phase);
    switch (exerciseId) {
      case "barbell_back_squat":
      case "barbell_front_squat":
      case "goblet_squat":
      case "hack_squat":
        this.poseSquat(exerciseId, amount);
        break;
      case "conventional_deadlift":
      case "romanian_deadlift":
        this.poseDeadlift(exerciseId, amount);
        break;
      case "barbell_bench_press":
      case "incline_barbell_bench_press":
      case "dumbbell_bench_press":
        this.poseBenchPress(exerciseId, amount);
        break;
      case "overhead_press":
      case "dumbbell_shoulder_press":
        this.poseOverheadPress(amount);
        break;
      case "bent_over_row":
      case "one_arm_dumbbell_row":
        this.poseBentRow(exerciseId, amount);
        break;
      case "chest_supported_row":
        this.poseChestSupportedRow(amount);
        break;
      case "seated_cable_row":
      case "resistance_band_row":
        this.poseSeatedRow(amount);
        break;
      case "pull_up":
      case "chin_up":
        this.posePullUp(amount);
        break;
      case "lat_pulldown":
        this.poseLatPulldown(amount);
        break;
      case "leg_press":
        this.poseLegPress(amount);
        break;
      case "dumbbell_lunge":
      case "bulgarian_split_squat":
      case "walking_lunge":
        this.poseLunge(exerciseId, amount, phase);
        break;
      case "biceps_curl":
      case "hammer_curl":
      case "preacher_curl":
        this.poseCurl(exerciseId, amount);
        break;
      case "triceps_pushdown":
        this.poseTricepsPushdown(amount);
        break;
      case "plank":
        this.posePlank(amount);
        break;
      case "leg_extension":
        this.poseLegExtension(amount);
        break;
      case "lying_leg_curl":
        this.poseLegCurl(amount);
        break;
      case "barbell_hip_thrust":
      case "glute_bridge":
        this.poseBridge(amount);
        break;
      case "standing_calf_raise":
      case "seated_calf_raise":
        this.poseCalfRaise(exerciseId, amount);
        break;
      case "push_up":
        this.posePushUp(amount);
        break;
      case "chest_fly":
      case "cable_crossover":
        this.poseFly(exerciseId, amount);
        break;
      case "machine_chest_press":
        this.poseMachinePress(amount);
        break;
      case "face_pull":
        this.poseFacePull(amount);
        break;
      case "lateral_raise":
        this.poseLateralRaise(amount);
        break;
      case "rear_delt_fly":
        this.poseRearDeltFly(amount);
        break;
      case "skull_crusher":
        this.poseSkullCrusher(amount);
        break;
      case "overhead_triceps_extension":
        this.poseOverheadTriceps(amount);
        break;
      case "parallel_bar_dip":
        this.poseDip(amount);
        break;
      case "hanging_leg_raise":
        this.poseHangingLegRaise(amount);
        break;
      case "cable_crunch":
        this.poseCableCrunch(amount);
        break;
      case "side_plank":
        this.poseSidePlank(amount);
        break;
      case "ab_wheel_rollout":
        this.poseAbRollout(amount);
        break;
      case "farmers_carry":
        this.poseGait(phase, false, true);
        break;
      case "kettlebell_swing":
        this.poseKettlebellSwing(amount);
        break;
      case "back_extension":
        this.poseBackExtension(amount);
        break;
      case "band_pull_apart":
        this.poseBandPullApart(amount);
        break;
      case "treadmill_run":
        this.poseGait(phase, true, false);
        break;
      case "indoor_cycling":
        this.poseCycling(phase);
        break;
      case "rowing_ergometer":
        this.poseRower(amount);
        break;
      case "stair_climber":
        this.poseStairs(phase);
        break;
      default:
        break;
    }
    this.root.updateMatrixWorld(true);
  }

  private reset(): void {
    this.root.position.set(0, 0.97, 0);
    this.root.rotation.set(0, 0, 0);
    this.pelvis.rotation.set(0, 0, 0);
    this.spine.rotation.set(0, 0, 0);
    this.chest.rotation.set(0, 0, 0);
    this.neck.rotation.set(0, 0, 0);
    for (const arm of [this.leftArm, this.rightArm]) {
      arm.shoulder.rotation.set(0, 0, 0);
      arm.elbow.rotation.set(0, 0, 0);
      arm.wrist.rotation.set(0, 0, 0);
    }
    for (const leg of [this.leftLeg, this.rightLeg]) {
      leg.hip.rotation.set(0, 0, 0);
      leg.knee.rotation.set(0, 0, 0);
      leg.ankle.rotation.set(0, 0, 0);
    }
  }

  private buildTorso(): void {
    const pelvisMesh = ellipsoid(0.23, 0.15, 0.17, shell);
    pelvisMesh.position.y = 0.015;
    this.pelvis.add(pelvisMesh);
    const hipBand = new THREE.Mesh(new THREE.TorusGeometry(0.205, 0.026, 12, 36), joint);
    hipBand.rotation.x = Math.PI / 2;
    hipBand.scale.z = 0.74;
    this.pelvis.add(hipBand);

    this.spine.position.y = 0.11;
    this.pelvis.add(this.spine);
    const abdomen = ellipsoid(0.17, 0.23, 0.145, joint);
    abdomen.position.y = 0.2;
    this.spine.add(abdomen);
    const corePanel = ellipsoid(0.13, 0.18, 0.155, shellDark);
    corePanel.position.set(0, 0.22, 0.018);
    this.spine.add(corePanel);

    this.chest.position.y = 0.34;
    this.spine.add(this.chest);
    const chestMesh = ellipsoid(0.29, 0.27, 0.165, shell);
    chestMesh.position.y = 0.22;
    this.chest.add(chestMesh);
    const sternum = ellipsoid(0.1, 0.2, 0.175, shellDark);
    sternum.position.set(0, 0.22, 0.035);
    this.chest.add(sternum);
    const clavicle = capsule(0.042, 0.5, shellDark);
    clavicle.rotation.z = Math.PI / 2;
    clavicle.position.y = 0.37;
    this.chest.add(clavicle);

    this.neck.position.y = 0.48;
    this.chest.add(this.neck);
    const neckMesh = capsule(0.075, 0.16, joint);
    neckMesh.position.y = 0.07;
    this.neck.add(neckMesh);
    const head = ellipsoid(0.135, 0.175, 0.135, shell);
    head.position.y = 0.27;
    this.neck.add(head);
    const face = ellipsoid(0.105, 0.12, 0.035, visor);
    face.position.set(0, 0.245, 0.125);
    face.rotation.x = -5 * DEG;
    this.neck.add(face);
  }

  private buildArm(side: Side): ArmRig {
    const direction = side === "left" ? 1 : -1;
    const shoulder = new THREE.Group();
    shoulder.position.set(direction * 0.275, 0.37, 0);
    shoulder.name = side === "left" ? "LeftShoulder" : "RightShoulder";
    this.chest.add(shoulder);
    const shoulderCap = ellipsoid(0.11, 0.115, 0.115, joint);
    shoulder.add(shoulderCap);

    const upperLength = 0.31;
    const upper = capsule(0.085, upperLength, shell);
    upper.position.y = -upperLength / 2;
    shoulder.add(upper);
    const upperPanel = capsule(0.046, upperLength * 0.72, shellDark);
    upperPanel.position.set(0, -upperLength * 0.46, 0.067);
    shoulder.add(upperPanel);

    const elbow = new THREE.Group();
    elbow.position.y = -upperLength;
    elbow.name = side === "left" ? "LeftElbow" : "RightElbow";
    shoulder.add(elbow);
    elbow.add(ellipsoid(0.078, 0.072, 0.075, joint));

    const forearmLength = 0.29;
    const forearm = capsule(0.068, forearmLength, shell);
    forearm.position.y = -forearmLength / 2;
    elbow.add(forearm);

    const wrist = new THREE.Group();
    wrist.position.y = -forearmLength;
    wrist.name = side === "left" ? "LeftHand" : "RightHand";
    elbow.add(wrist);
    const hand = ellipsoid(0.075, 0.105, 0.06, shell);
    hand.position.y = -0.055;
    wrist.add(hand);
    const palm = ellipsoid(0.056, 0.078, 0.061, shellDark);
    palm.position.set(0, -0.052, 0.025);
    wrist.add(palm);
    return { shoulder, elbow, wrist };
  }

  private buildLeg(side: Side): LegRig {
    const direction = side === "left" ? 1 : -1;
    const hip = new THREE.Group();
    hip.position.set(direction * 0.135, -0.055, 0);
    hip.name = side === "left" ? "LeftHip" : "RightHip";
    this.pelvis.add(hip);
    hip.add(ellipsoid(0.115, 0.105, 0.11, joint));

    const thighLength = 0.43;
    const thigh = capsule(0.115, thighLength, shell);
    thigh.position.y = -thighLength / 2;
    hip.add(thigh);
    const quad = capsule(0.066, thighLength * 0.68, shellDark);
    quad.position.set(0, -thighLength * 0.45, 0.088);
    hip.add(quad);

    const knee = new THREE.Group();
    knee.position.y = -thighLength;
    knee.name = side === "left" ? "LeftKnee" : "RightKnee";
    hip.add(knee);
    knee.add(ellipsoid(0.098, 0.09, 0.095, joint));

    const shinLength = 0.42;
    const shin = capsule(0.085, shinLength, shell);
    shin.position.y = -shinLength / 2;
    knee.add(shin);
    const calf = capsule(0.05, shinLength * 0.58, shellDark);
    calf.position.set(0, -shinLength * 0.42, -0.067);
    knee.add(calf);

    const ankle = new THREE.Group();
    ankle.position.y = -shinLength;
    ankle.name = side === "left" ? "LeftFoot" : "RightFoot";
    knee.add(ankle);
    ankle.add(ellipsoid(0.062, 0.065, 0.06, joint));
    const foot = capsule(0.07, 0.22, shell);
    foot.rotation.x = Math.PI / 2;
    foot.position.set(0, -0.035, 0.09);
    ankle.add(foot);
    return { hip, knee, ankle };
  }

  private arm(side: Side, flexion = 0, abduction = 0, elbow = 0, twist = 0): void {
    const rig = side === "left" ? this.leftArm : this.rightArm;
    const mirror = side === "left" ? 1 : -1;
    rig.shoulder.rotation.set(flexion * DEG, twist * DEG * mirror, abduction * DEG * mirror);
    rig.elbow.rotation.x = elbow * DEG;
  }

  private leg(side: Side, hip = 0, knee = 0, ankle = 0, abduction = 0): void {
    const rig = side === "left" ? this.leftLeg : this.rightLeg;
    const mirror = side === "left" ? 1 : -1;
    rig.hip.rotation.set(hip * DEG, 0, abduction * DEG * mirror);
    rig.knee.rotation.x = knee * DEG;
    rig.ankle.rotation.x = ankle * DEG;
  }

  private poseSquat(id: string, amount: number): void {
    this.root.position.y -= 0.31 * amount;
    this.root.position.z -= 0.06 * amount;
    this.spine.rotation.x = 13 * amount * DEG;
    this.leg("left", -68 * amount, 108 * amount, -35 * amount, 4);
    this.leg("right", -68 * amount, 108 * amount, -35 * amount, 4);
    if (id === "barbell_front_squat") {
      this.arm("left", -84, 18, -102);
      this.arm("right", -84, 18, -102);
    } else if (id === "goblet_squat") {
      this.arm("left", -30, 14, -112, -18);
      this.arm("right", -30, 14, -112, -18);
    } else if (id === "hack_squat") {
      this.arm("left", 8, 5, -18);
      this.arm("right", 8, 5, -18);
      this.spine.rotation.x = 3 * amount * DEG;
    } else {
      this.arm("left", 34, 62, 102);
      this.arm("right", 34, 62, 102);
    }
  }

  private poseDeadlift(id: string, amount: number): void {
    const romanian = id === "romanian_deadlift";
    const torso = (romanian ? 56 : 44) * amount;
    this.root.position.y -= (romanian ? 0.06 : 0.14) * amount;
    this.root.position.z -= 0.08 * amount;
    this.spine.rotation.x = torso * DEG;
    this.leg("left", -(romanian ? 20 : 38) * amount, (romanian ? 28 : 62) * amount);
    this.leg("right", -(romanian ? 20 : 38) * amount, (romanian ? 28 : 62) * amount);
    this.arm("left", -torso, 7, 0);
    this.arm("right", -torso, 7, 0);
  }

  private poseBenchPress(id: string, amount: number): void {
    const incline = id === "incline_barbell_bench_press";
    this.root.rotation.x = (incline ? -62 : -90) * DEG;
    this.root.position.set(0, incline ? 0.62 : 0.52, 0.04);
    const spread = (id === "dumbbell_bench_press" ? 74 : 66) * (1 - amount);
    this.arm("left", -88 * amount, spread, -92 * (1 - amount));
    this.arm("right", -88 * amount, spread, -92 * (1 - amount));
    this.leg("left", -26, 58, -20, 10);
    this.leg("right", -26, 58, -20, 10);
  }

  private poseOverheadPress(amount: number): void {
    this.spine.rotation.x = -4 * amount * DEG;
    this.arm("left", -58 - 118 * amount, 38 * (1 - amount), -98 * (1 - amount));
    this.arm("right", -58 - 118 * amount, 38 * (1 - amount), -98 * (1 - amount));
  }

  private poseBentRow(id: string, amount: number): void {
    const oneArm = id === "one_arm_dumbbell_row";
    this.spine.rotation.x = 48 * DEG;
    this.leg("left", -16, 24);
    this.leg("right", -16, 24);
    this.arm("left", -48 + 30 * amount, oneArm ? 8 : 18, -105 * amount);
    this.arm("right", -48 + (oneArm ? 0 : 30) * amount, oneArm ? 28 : 18, oneArm ? 0 : -105 * amount);
  }

  private poseChestSupportedRow(amount: number): void {
    this.root.position.set(0, 0.91, -0.04);
    this.spine.rotation.x = 42 * DEG;
    this.leg("left", -12, 18);
    this.leg("right", -12, 18);
    this.arm("left", -42 + 28 * amount, 16, -102 * amount);
    this.arm("right", -42 + 28 * amount, 16, -102 * amount);
  }

  private poseSeatedRow(amount: number): void {
    this.root.position.y = 0.52;
    this.leg("left", -88, 92);
    this.leg("right", -88, 92);
    this.spine.rotation.x = 8 * (1 - amount) * DEG;
    this.arm("left", -90 + 28 * amount, 12, -102 * amount);
    this.arm("right", -90 + 28 * amount, 12, -102 * amount);
  }

  private posePullUp(amount: number): void {
    this.root.position.y = 0.78 + 0.2 * amount;
    this.arm("left", -176 + 36 * amount, 22 + 34 * amount, -102 * amount);
    this.arm("right", -176 + 36 * amount, 22 + 34 * amount, -102 * amount);
    this.leg("left", 4, 10);
    this.leg("right", 4, 10);
  }

  private poseLatPulldown(amount: number): void {
    this.root.position.y = 0.54;
    this.leg("left", -86, 92);
    this.leg("right", -86, 92);
    this.arm("left", -174 + 62 * amount, 25 + 35 * amount, -104 * amount);
    this.arm("right", -174 + 62 * amount, 25 + 35 * amount, -104 * amount);
  }

  private poseLegPress(amount: number): void {
    this.root.rotation.x = -52 * DEG;
    this.root.position.set(0, 0.56, 0.16);
    const bend = 1 - amount;
    this.leg("left", -28 - 62 * bend, 24 + 92 * bend, -18 * bend, 8);
    this.leg("right", -28 - 62 * bend, 24 + 92 * bend, -18 * bend, 8);
    this.arm("left", -18, 8, -15);
    this.arm("right", -18, 8, -15);
  }

  private poseLunge(id: string, amount: number, phase: number): void {
    const alternate = id === "walking_lunge" && phase >= 0.5;
    const leftFront = !alternate;
    this.root.position.y -= 0.28 * amount;
    this.root.position.z += (leftFront ? 0.02 : -0.02) * amount;
    this.spine.rotation.x = 7 * amount * DEG;
    this.leg("left", (leftFront ? -55 : 27) * amount, (leftFront ? 96 : 82) * amount);
    this.leg("right", (leftFront ? 27 : -55) * amount, (leftFront ? 82 : 96) * amount);
    this.arm("left", 0, 4, -8);
    this.arm("right", 0, 4, -8);
  }

  private poseCurl(id: string, amount: number): void {
    const preacher = id === "preacher_curl";
    this.spine.rotation.x = (preacher ? 8 : 0) * DEG;
    this.arm("left", preacher ? -35 : 0, 7, -118 * amount, id === "hammer_curl" ? -20 : 0);
    this.arm("right", preacher ? -35 : 0, 7, -118 * amount, id === "hammer_curl" ? -20 : 0);
  }

  private poseTricepsPushdown(amount: number): void {
    this.spine.rotation.x = 6 * DEG;
    this.arm("left", -12, 6, -102 * (1 - amount));
    this.arm("right", -12, 6, -102 * (1 - amount));
  }

  private posePlank(amount: number): void {
    this.root.rotation.x = 90 * DEG;
    this.root.position.set(0, 0.5 + 0.012 * amount, 0);
    this.arm("left", -88, 8, -92);
    this.arm("right", -88, 8, -92);
  }

  private poseLegExtension(amount: number): void {
    this.root.position.y = 0.54;
    this.leg("left", -88, 92 * (1 - amount));
    this.leg("right", -88, 92 * (1 - amount));
    this.arm("left", 8, 4, -10);
    this.arm("right", 8, 4, -10);
  }

  private poseLegCurl(amount: number): void {
    this.root.rotation.x = 90 * DEG;
    this.root.position.set(0, 0.55, 0);
    this.leg("left", 0, 112 * amount);
    this.leg("right", 0, 112 * amount);
    this.arm("left", -40, 8, -50);
    this.arm("right", -40, 8, -50);
  }

  private poseBridge(amount: number): void {
    this.root.rotation.x = -90 * DEG;
    this.root.position.set(0, 0.34 + 0.22 * amount, 0);
    this.leg("left", -52, 96);
    this.leg("right", -52, 96);
    this.arm("left", 0, 58, 0);
    this.arm("right", 0, 58, 0);
  }

  private poseCalfRaise(id: string, amount: number): void {
    if (id === "seated_calf_raise") {
      this.root.position.y = 0.54;
      this.leg("left", -88, 92, -18 * amount);
      this.leg("right", -88, 92, -18 * amount);
    } else {
      this.root.position.y += 0.07 * amount;
      this.leg("left", 0, 0, -16 * amount);
      this.leg("right", 0, 0, -16 * amount);
    }
  }

  private posePushUp(amount: number): void {
    this.root.rotation.x = 90 * DEG;
    this.root.position.set(0, 0.43 - 0.12 * amount, 0);
    this.arm("left", -92, 28, -82 * amount);
    this.arm("right", -92, 28, -82 * amount);
  }

  private poseFly(id: string, amount: number): void {
    if (id === "chest_fly") {
      this.root.rotation.x = -90 * DEG;
      this.root.position.set(0, 0.52, 0);
    } else {
      this.spine.rotation.x = 7 * DEG;
    }
    const spread = 82 * (1 - amount) + 12 * amount;
    this.arm("left", -88, spread, -14);
    this.arm("right", -88, spread, -14);
  }

  private poseMachinePress(amount: number): void {
    this.root.position.y = 0.54;
    this.leg("left", -88, 92);
    this.leg("right", -88, 92);
    this.arm("left", -88 * amount, 26 * (1 - amount), -90 * (1 - amount));
    this.arm("right", -88 * amount, 26 * (1 - amount), -90 * (1 - amount));
  }

  private poseFacePull(amount: number): void {
    this.arm("left", -82, 20 + 38 * amount, -25 - 88 * amount);
    this.arm("right", -82, 20 + 38 * amount, -25 - 88 * amount);
  }

  private poseLateralRaise(amount: number): void {
    this.arm("left", 0, 86 * amount, -8);
    this.arm("right", 0, 86 * amount, -8);
  }

  private poseRearDeltFly(amount: number): void {
    this.spine.rotation.x = 46 * DEG;
    this.arm("left", -46, 82 * amount, -12);
    this.arm("right", -46, 82 * amount, -12);
  }

  private poseSkullCrusher(amount: number): void {
    this.root.rotation.x = -90 * DEG;
    this.root.position.set(0, 0.52, 0);
    this.arm("left", -90, 10, -108 * (1 - amount));
    this.arm("right", -90, 10, -108 * (1 - amount));
  }

  private poseOverheadTriceps(amount: number): void {
    this.arm("left", -174, 14, -116 * (1 - amount));
    this.arm("right", -174, 14, -116 * (1 - amount));
  }

  private poseDip(amount: number): void {
    this.root.position.y = 1.45 - 0.2 * amount;
    this.spine.rotation.x = 10 * amount * DEG;
    this.arm("left", 8, 7, -88 * amount);
    this.arm("right", 8, 7, -88 * amount);
    this.leg("left", 4, 20);
    this.leg("right", 4, 20);
  }

  private poseHangingLegRaise(amount: number): void {
    this.root.position.y = 0.78;
    this.arm("left", -176, 26, 0);
    this.arm("right", -176, 26, 0);
    this.leg("left", -88 * amount, 16 * amount);
    this.leg("right", -88 * amount, 16 * amount);
  }

  private poseCableCrunch(amount: number): void {
    this.root.position.y = 0.58;
    this.leg("left", -6, 108, 18);
    this.leg("right", -6, 108, 18);
    this.spine.rotation.x = 52 * amount * DEG;
    this.arm("left", -38, 12, -105);
    this.arm("right", -38, 12, -105);
  }

  private poseSidePlank(amount: number): void {
    this.root.rotation.set(90 * DEG, -90 * DEG, 0);
    this.root.position.set(0, 0.34 + 0.012 * amount, 0);
    this.arm("left", 0, 90, -88);
    this.arm("right", 0, 90, 0);
  }

  private poseAbRollout(amount: number): void {
    this.root.rotation.x = 90 * DEG;
    this.root.position.set(0, 0.54, -0.22 * amount);
    this.leg("left", -15 * (1 - amount), 48);
    this.leg("right", -15 * (1 - amount), 48);
    this.arm("left", -92 - 20 * amount, 7, -8);
    this.arm("right", -92 - 20 * amount, 7, -8);
  }

  private poseGait(phase: number, running: boolean, loaded: boolean): void {
    const wave = Math.sin(phase * Math.PI * 2);
    const legSwing = running ? 42 : 24;
    const armSwing = running ? 34 : 20;
    this.root.position.y += (1 - Math.cos(phase * Math.PI * (running ? 4 : 2))) * (running ? 0.025 : 0.01);
    this.spine.rotation.x = (running ? 8 : 2) * DEG;
    this.leg("left", -legSwing * wave, Math.max(0, 72 * wave));
    this.leg("right", legSwing * wave, Math.max(0, -72 * wave));
    if (loaded) {
      this.arm("left", 0, 5, -8);
      this.arm("right", 0, 5, -8);
    } else {
      this.arm("left", armSwing * wave, 4, running ? -62 : -20);
      this.arm("right", -armSwing * wave, 4, running ? -62 : -20);
    }
  }

  private poseKettlebellSwing(amount: number): void {
    const setup = 1 - amount;
    this.root.position.y -= 0.12 * setup;
    this.spine.rotation.x = 46 * setup * DEG;
    this.leg("left", -26 * setup, 42 * setup);
    this.leg("right", -26 * setup, 42 * setup);
    this.arm("left", -92 * amount - 46 * setup, 8, 0);
    this.arm("right", -92 * amount - 46 * setup, 8, 0);
  }

  private poseBackExtension(amount: number): void {
    this.root.rotation.x = 90 * DEG;
    this.root.position.set(0, 0.62, 0);
    this.spine.rotation.x = -44 * (1 - amount) * DEG;
    this.arm("left", -20, 12, -90);
    this.arm("right", -20, 12, -90);
  }

  private poseBandPullApart(amount: number): void {
    this.arm("left", -88, 8 + 68 * amount, -7);
    this.arm("right", -88, 8 + 68 * amount, -7);
  }

  private poseCycling(phase: number): void {
    const wave = Math.sin(phase * Math.PI * 2);
    const left = (wave + 1) / 2;
    const right = 1 - left;
    this.root.position.set(0, 1.02, -0.1);
    this.spine.rotation.x = 30 * DEG;
    this.leg("left", -48 - 40 * left, 36 + 76 * left);
    this.leg("right", -48 - 40 * right, 36 + 76 * right);
    this.arm("left", -58, 8, -18);
    this.arm("right", -58, 8, -18);
  }

  private poseRower(amount: number): void {
    const catchAmount = 1 - amount;
    this.root.position.set(0, 0.54, 0.18 * amount);
    this.spine.rotation.x = (26 * catchAmount - 12 * amount) * DEG;
    this.leg("left", -34 - 50 * catchAmount, 34 + 74 * catchAmount);
    this.leg("right", -34 - 50 * catchAmount, 34 + 74 * catchAmount);
    this.arm("left", -64 * catchAmount + 20 * amount, 8, -102 * amount);
    this.arm("right", -64 * catchAmount + 20 * amount, 8, -102 * amount);
  }

  private poseStairs(phase: number): void {
    const wave = Math.sin(phase * Math.PI * 2);
    const left = Math.max(0, wave);
    const right = Math.max(0, -wave);
    this.spine.rotation.x = 8 * DEG;
    this.leg("left", -52 * left, 78 * left);
    this.leg("right", -52 * right, 78 * right);
    this.arm("left", -24, 7, -20);
    this.arm("right", -24, 7, -20);
  }
}

function repAmount(phase: number): number {
  const wave = (1 - Math.cos(phase * Math.PI * 2)) / 2;
  return THREE.MathUtils.smoothstep(wave, 0, 1);
}

function capsule(radius: number, totalLength: number, material: THREE.Material): THREE.Mesh {
  return new THREE.Mesh(
    new THREE.CapsuleGeometry(radius, Math.max(0.01, totalLength - radius * 2), 8, 20),
    material,
  );
}

function ellipsoid(
  x: number,
  y: number,
  z: number,
  material: THREE.Material,
): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(1, 30, 22), material);
  mesh.scale.set(x, y, z);
  return mesh;
}
