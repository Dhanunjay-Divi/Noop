import http from "k6/http";
import { check, fail } from "k6";

export const options = {
  scenarios: {
    sync_burst: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.NOOP_LOAD_RPS || 100),
      timeUnit: "1s",
      duration: __ENV.NOOP_LOAD_DURATION || "15m",
      preAllocatedVUs: Number(__ENV.NOOP_LOAD_PREALLOCATED_VUS || 200),
      maxVUs: Number(__ENV.NOOP_LOAD_MAX_VUS || 1000),
    },
  },
  thresholds: {
    dropped_iterations: ["count==0"],
    http_req_failed: ["rate<0.001"],
    http_req_duration: ["p(95)<500", "p(99)<1000"],
    checks: ["rate>0.999"],
  },
};

const baseUrl = (__ENV.NOOP_LOAD_BASE_URL || "").replace(/\/+$/, "");
const token = __ENV.NOOP_LOAD_API_TOKEN || "";
const credentialsPath = __ENV.NOOP_LOAD_CREDENTIALS_FILE || "";
const installationCredentials = credentialsPath
  ? JSON.parse(open(credentialsPath))
  : [];
const samplesPerSync = Number(__ENV.NOOP_LOAD_SAMPLES_PER_SYNC || 60);

function uuidV4() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (marker) => {
    const value = Math.floor(Math.random() * 16);
    const nibble = marker === "x" ? value : (value & 0x3) | 0x8;
    return nibble.toString(16);
  });
}

export function setup() {
  if (__ENV.NOOP_LOAD_ALLOW_WRITES !== "I_UNDERSTAND_THIS_IS_DESTRUCTIVE") {
    fail("Refusing writes without NOOP_LOAD_ALLOW_WRITES acknowledgement");
  }
  if (__ENV.NOOP_LOAD_RATE_LIMITS_RAISED !== "I_CONFIGURED_TEST_LIMITS") {
    fail("Refusing a misleading run until test-target rate limits are raised");
  }
  if (!baseUrl || (!token && installationCredentials.length === 0)) {
    fail(
      "NOOP_LOAD_BASE_URL plus NOOP_LOAD_API_TOKEN or " +
        "NOOP_LOAD_CREDENTIALS_FILE are required",
    );
  }
  if (
    installationCredentials.length > 0 &&
    installationCredentials.some(
      (item) =>
        typeof item.installation_id !== "string" ||
        !item.token?.startsWith("noop_install_"),
    )
  ) {
    fail("NOOP_LOAD_CREDENTIALS_FILE contains an invalid entry");
  }
  if (
    !Number.isInteger(samplesPerSync) ||
    samplesPerSync < 1 ||
    samplesPerSync > 3600
  ) {
    fail("NOOP_LOAD_SAMPLES_PER_SYNC must be an integer from 1 through 3600");
  }
  const ready = http.get(`${baseUrl}/readyz`);
  check(ready, { "target is ready": (response) => response.status === 200 });
}

export default function () {
  const batchId = uuidV4();
  const credential =
    installationCredentials.length > 0
      ? installationCredentials[(__VU - 1) % installationCredentials.length]
      : null;
  const installationId =
    credential?.installation_id ||
    `00000000-0000-4000-8000-${String(__VU).padStart(12, "0")}`;
  const bearerToken = credential?.token || token;
  const now = new Date();
  const deviceId = `ios:${installationId}:load-${__VU}-strap`;
  const hr = Array.from({ length: samplesPerSync }, (_, index) => ({
    recorded_at: Math.floor(
      (now.getTime() - (samplesPerSync - index - 1) * 5000) / 1000,
    ),
    value: 62 + (index % 24),
    metadata: { unit: "bpm" },
  }));
  const payload = {
    schema_version: 1,
    batch_id: batchId,
    source: {
      device_id: deviceId,
      sent_at: now.toISOString(),
      app_version: "capacity-test",
      platform: "ios",
      device: { display_name: "Capacity fixture" },
      metadata: {
        installation_id: installationId,
        logical_source_id: `load-${__VU}-strap`,
        namespace: "strap_measured",
        paired_device_id: `load-${__VU}`,
        privacy: "explicit_opt_in",
        score_provenance: "strap_measured",
      },
    },
    streams: {
      hr,
      rr: [],
      battery: [],
      spo2: [],
      skin_temp: [],
      respiration: [],
      steps: [],
      events: [],
    },
    daily_metrics: {},
    sleep_sessions: [],
    workouts: [],
    journal: [],
  };
  const response = http.post(
    `${baseUrl}/v1/sync`,
    JSON.stringify(payload),
    {
      headers: {
        Authorization: `Bearer ${bearerToken}`,
        "Content-Type": "application/json",
        "Idempotency-Key": batchId,
      },
      tags: { route: "sync" },
    },
  );
  check(response, {
    "sync accepted": (result) => result.status === 200,
  });
}
