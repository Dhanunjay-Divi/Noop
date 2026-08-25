import { check, fail } from "k6";
import http from "k6/http";
import { Counter, Rate } from "k6/metrics";

const mixedRate = Number(__ENV.NOOP_LOAD_MIXED_ITERATIONS_PER_SECOND || 100);
const adversarialRate = Number(
  __ENV.NOOP_LOAD_ADVERSARIAL_ITERATIONS_PER_SECOND || 5,
);
const preAllocatedVUs = Number(
  __ENV.NOOP_LOAD_PREALLOCATED_VUS || 200,
);
const maxVUs = Number(__ENV.NOOP_LOAD_MAX_VUS || 1000);
const duration = __ENV.NOOP_LOAD_DURATION || "15m";

export const options = {
  scenarios: {
    mixed_traffic: {
      executor: "constant-arrival-rate",
      exec: "mixedTraffic",
      rate: mixedRate,
      timeUnit: "1s",
      duration,
      preAllocatedVUs,
      maxVUs,
      tags: { traffic: "mixed" },
    },
    tenant_adversarial: {
      executor: "constant-arrival-rate",
      exec: "tenantAdversarial",
      rate: adversarialRate,
      timeUnit: "1s",
      duration,
      preAllocatedVUs: Math.max(2, Math.ceil(preAllocatedVUs / 10)),
      maxVUs: Math.max(10, Math.ceil(maxVUs / 5)),
      tags: { traffic: "adversarial" },
    },
  },
  thresholds: {
    dropped_iterations: ["count==0"],
    http_req_failed: ["rate<0.001"],
    "http_req_duration{traffic:mixed}": ["p(95)<500", "p(99)<1000"],
    "http_req_duration{traffic:adversarial}": ["p(95)<500", "p(99)<1000"],
    legitimate_contract_failures: ["rate<0.001"],
    isolation_violations: ["count==0"],
    checks: ["rate>0.999"],
  },
};

const baseUrl = (__ENV.NOOP_LOAD_BASE_URL || "").replace(/\/+$/, "");
const credentialsPath = __ENV.NOOP_LOAD_CREDENTIALS_FILE || "";
const installationCredentials = credentialsPath
  ? JSON.parse(open(credentialsPath))
  : [];
const minimumCredentials = Number(__ENV.NOOP_LOAD_MIN_CREDENTIALS || 2);
const legitimateContractFailures = new Rate("legitimate_contract_failures");
const isolationViolations = new Counter("isolation_violations");
let ownedDeviceReady = false;

function uuidV4() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (marker) => {
    const value = Math.floor(Math.random() * 16);
    const nibble = marker === "x" ? value : (value & 0x3) | 0x8;
    return nibble.toString(16);
  });
}

function headers(token, batchId = null) {
  const values = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  };
  if (batchId) {
    values["Idempotency-Key"] = batchId;
  }
  return values;
}

function syncPayload(credential, deviceId, marker) {
  const now = new Date();
  const batchId = uuidV4();
  return {
    batchId,
    body: {
      schema_version: 1,
      batch_id: batchId,
      source: {
        device_id: deviceId,
        sent_at: now.toISOString(),
        app_version: "mixed-capacity-test",
        platform: "ios",
        device: { display_name: "Disposable capacity fixture" },
        metadata: {
          installation_id: credential.installation_id,
          logical_source_id: marker,
          namespace: "strap_measured",
          paired_device_id: marker,
          privacy: "explicit_opt_in",
          score_provenance: "strap_measured",
        },
      },
      streams: {
        hr: [
          {
            recorded_at: Math.floor(now.getTime() / 1000),
            value: 70 + Math.floor(Math.random() * 20),
            metadata: { unit: "bpm" },
          },
        ],
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
    },
  };
}

function postSync(credential, deviceId, marker, tags = {}) {
  const payload = syncPayload(credential, deviceId, marker);
  return http.post(`${baseUrl}/v1/sync`, JSON.stringify(payload.body), {
    headers: headers(credential.token, payload.batchId),
    responseCallback: http.expectedStatuses(200),
    tags: { route: "sync", ...tags },
  });
}

function recordLegitimate(response, label) {
  const accepted = response.status === 200;
  legitimateContractFailures.add(!accepted);
  check(response, { [label]: () => accepted });
  return accepted;
}

function recordDenied(response, expectedStatus, label) {
  const denied = response.status === expectedStatus;
  if (!denied) {
    isolationViolations.add(1);
  }
  check(response, { [label]: () => denied });
}

function validatePositiveInteger(value, name) {
  if (!Number.isInteger(value) || value < 1) {
    fail(`${name} must be a positive integer`);
  }
}

export function setup() {
  if (
    __ENV.NOOP_LOAD_TARGET_IS_DISPOSABLE !==
    "I_CONFIRMED_THIS_TARGET_IS_DISPOSABLE"
  ) {
    fail("Refusing to run without disposable-target confirmation");
  }
  if (__ENV.NOOP_LOAD_ALLOW_WRITES !== "I_UNDERSTAND_THIS_IS_DESTRUCTIVE") {
    fail("Refusing writes without NOOP_LOAD_ALLOW_WRITES acknowledgement");
  }
  if (
    __ENV.NOOP_LOAD_ALLOW_ADVERSARIAL !==
    "I_UNDERSTAND_CROSS_TENANT_DELETE_PROBES_CAN_DESTROY_A_BROKEN_TARGET"
  ) {
    fail("Refusing tenant-adversarial probes without explicit acknowledgement");
  }
  if (__ENV.NOOP_LOAD_RATE_LIMITS_RAISED !== "I_CONFIGURED_TEST_LIMITS") {
    fail("Refusing a misleading run until disposable-target limits are raised");
  }
  if (
    !baseUrl ||
    (!baseUrl.startsWith("https://") &&
      !baseUrl.startsWith("http://127.0.0.1") &&
      !baseUrl.startsWith("http://localhost"))
  ) {
    fail("NOOP_LOAD_BASE_URL must use HTTPS except on loopback");
  }
  for (const [value, name] of [
    [mixedRate, "NOOP_LOAD_MIXED_ITERATIONS_PER_SECOND"],
    [adversarialRate, "NOOP_LOAD_ADVERSARIAL_ITERATIONS_PER_SECOND"],
    [preAllocatedVUs, "NOOP_LOAD_PREALLOCATED_VUS"],
    [maxVUs, "NOOP_LOAD_MAX_VUS"],
    [minimumCredentials, "NOOP_LOAD_MIN_CREDENTIALS"],
  ]) {
    validatePositiveInteger(value, name);
  }
  if (preAllocatedVUs > maxVUs) {
    fail("NOOP_LOAD_PREALLOCATED_VUS cannot exceed NOOP_LOAD_MAX_VUS");
  }
  if (
    !Array.isArray(installationCredentials) ||
    installationCredentials.length < Math.max(2, minimumCredentials)
  ) {
    fail("A shared-mode credential file with enough disposable tenants is required");
  }
  if (
    installationCredentials.some(
      (item) =>
        typeof item.installation_id !== "string" ||
        !item.token?.startsWith("noop_install_"),
    )
  ) {
    fail("NOOP_LOAD_CREDENTIALS_FILE contains an invalid entry");
  }
  const installationIds = new Set(
    installationCredentials.map((item) => item.installation_id),
  );
  const tokens = new Set(installationCredentials.map((item) => item.token));
  if (
    installationIds.size !== installationCredentials.length ||
    tokens.size !== installationCredentials.length
  ) {
    fail("Disposable installation IDs and credentials must be unique");
  }

  const ready = http.get(`${baseUrl}/readyz`, {
    responseCallback: http.expectedStatuses(200),
    tags: { route: "readyz", traffic: "setup" },
  });
  if (!check(ready, { "target is ready": (response) => response.status === 200 })) {
    fail("Target readiness failed");
  }
  for (const credential of installationCredentials.slice(0, 2)) {
    const status = http.get(`${baseUrl}/v1/status`, {
      headers: headers(credential.token),
      responseCallback: http.expectedStatuses(200),
      tags: { route: "status", traffic: "setup" },
    });
    if (
      status.status !== 200 ||
      status.json("scope") !== "installation"
    ) {
      fail("Mixed/adversarial harness requires NOOP_AUTH_MODE=shared");
    }
  }

  const attacker = installationCredentials[0];
  const victim = installationCredentials[1];
  const victimDeviceId = `ios:${victim.installation_id}:adversarial-canary`;
  const attackerDeviceId = `ios:${attacker.installation_id}:adversarial-canary`;
  if (
    !recordLegitimate(
      postSync(victim, victimDeviceId, "adversarial-canary", {
        traffic: "setup",
      }),
      "victim canary seeded",
    ) ||
    !recordLegitimate(
      postSync(attacker, attackerDeviceId, "adversarial-canary", {
        traffic: "setup",
      }),
      "attacker canary seeded",
    )
  ) {
    fail("Could not seed disposable adversarial canaries");
  }
  return { attacker, victim, victimDeviceId };
}

export function mixedTraffic() {
  const credential =
    installationCredentials[(__VU - 1) % installationCredentials.length];
  const marker = `mixed-${__VU}-strap`;
  const deviceId = `ios:${credential.installation_id}:${marker}`;
  const encodedDevice = encodeURIComponent(deviceId);

  if (!ownedDeviceReady) {
    ownedDeviceReady = recordLegitimate(
      postSync(credential, deviceId, marker, { traffic: "mixed" }),
      "mixed device seeded",
    );
    if (!ownedDeviceReady) {
      return;
    }
  }

  const operation = __ITER % 10;
  let response;
  let label;
  if (operation < 3) {
    response = postSync(credential, deviceId, marker, { traffic: "mixed" });
    label = "mixed sync accepted";
  } else if (operation === 3) {
    response = http.get(`${baseUrl}/v1/devices`, {
      headers: headers(credential.token),
      responseCallback: http.expectedStatuses(200),
      tags: { route: "devices", traffic: "mixed" },
    });
    label = "owned devices read";
  } else if (operation === 4) {
    response = http.get(`${baseUrl}/v1/installation/me`, {
      headers: headers(credential.token),
      responseCallback: http.expectedStatuses(200),
      tags: { route: "installation_me", traffic: "mixed" },
    });
    label = "installation read";
  } else if (operation < 7) {
    response = http.get(`${baseUrl}/v1/devices/${encodedDevice}/latest`, {
      headers: headers(credential.token),
      responseCallback: http.expectedStatuses(200),
      tags: { route: "latest", traffic: "mixed" },
    });
    label = "latest metrics read";
  } else if (operation === 7) {
    const end = new Date();
    const start = new Date(end.getTime() - 60 * 60 * 1000);
    response = http.get(
      `${baseUrl}/v1/devices/${encodedDevice}/streams/hr` +
        `?start=${encodeURIComponent(start.toISOString())}` +
        `&end=${encodeURIComponent(end.toISOString())}&limit=1000`,
      {
        headers: headers(credential.token),
        responseCallback: http.expectedStatuses(200),
        tags: { route: "stream_range", traffic: "mixed" },
      },
    );
    label = "metric range read";
  } else if (operation === 8) {
    response = http.get(`${baseUrl}/v1/devices/${encodedDevice}/daily`, {
      headers: headers(credential.token),
      responseCallback: http.expectedStatuses(200),
      tags: { route: "daily", traffic: "mixed" },
    });
    label = "daily metrics read";
  } else {
    const end = new Date();
    const start = new Date(end.getTime() - 15 * 60 * 1000);
    response = http.get(
      `${baseUrl}/v1/devices/${encodedDevice}/export` +
        `?start=${encodeURIComponent(start.toISOString())}` +
        `&end=${encodeURIComponent(end.toISOString())}`,
      {
        headers: headers(credential.token),
        responseCallback: http.expectedStatuses(200),
        tags: { route: "bounded_export", traffic: "mixed" },
      },
    );
    label = "bounded export read";
  }
  recordLegitimate(response, label);
}

export function tenantAdversarial(data) {
  const { attacker, victim, victimDeviceId } = data;
  const encodedVictimDevice = encodeURIComponent(victimDeviceId);
  const attackerHeaders = headers(attacker.token);
  const deniedRead = http.expectedStatuses(404);
  const deniedWrite = http.expectedStatuses(403);

  recordDenied(
    http.get(`${baseUrl}/v1/devices/${encodedVictimDevice}/latest`, {
      headers: attackerHeaders,
      responseCallback: deniedRead,
      tags: { route: "foreign_latest", traffic: "adversarial" },
    }),
    404,
    "cross-tenant latest denied",
  );
  recordDenied(
    http.get(`${baseUrl}/v1/devices/${encodedVictimDevice}/export`, {
      headers: attackerHeaders,
      responseCallback: deniedRead,
      tags: { route: "foreign_export", traffic: "adversarial" },
    }),
    404,
    "cross-tenant export denied",
  );
  recordDenied(
    http.del(`${baseUrl}/v1/devices/${encodedVictimDevice}`, null, {
      headers: {
        ...attackerHeaders,
        "X-Noop-Confirm": `DELETE ${victimDeviceId}`,
      },
      responseCallback: deniedRead,
      tags: { route: "foreign_delete", traffic: "adversarial" },
    }),
    404,
    "cross-tenant delete denied",
  );

  const forged = syncPayload(
    victim,
    victimDeviceId,
    "adversarial-canary",
  );
  recordDenied(
    http.post(`${baseUrl}/v1/sync`, JSON.stringify(forged.body), {
      headers: headers(attacker.token, forged.batchId),
      responseCallback: deniedWrite,
      tags: { route: "forged_sync", traffic: "adversarial" },
    }),
    403,
    "forged namespace sync denied",
  );
}
