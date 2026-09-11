# NOOP Product And Health-Safety Contracts

Read this reference when work changes health metrics, recommendations, daily
guidance, body/weight features, workout detection or coaching, nutrition,
notifications, exercise media, or Safety/SOS.

## Product Experience

- Build the usable product, not a marketing explanation. Today should answer:
  what is my state, how certain is it, what changed, and what should I do next?
- Lead with Recovery, Sleep, Effort, Fitness Age or the relevant metric. Keep
  calibration and missing states visible. Collapse repeated explanatory prose
  behind an accessible info/detail action.
- Do not replace evidence with polish. A high-quality empty state says what is
  missing and the minimum next step; it does not fabricate a score or fill the
  screen with generic education.
- Preserve Apple/Android meaning, consent, routes, and states. Native rendering
  may differ when platform conventions require it, but one platform must not
  expose stronger claims or hidden defaults.
- Notifications are private doorways. Detailed health values, journal content,
  event titles, exact calendar times, and sensitive interpretations belong
  inside the opened app unless a separately reviewed design explicitly allows
  them.

### Owner Visual And Guidance Direction

- Treat the current NOOP desktop Today reference as the owner-preferred visual
  direction: quiet black shell, restrained sidebar, compact metric hierarchy,
  visible calibration/status, thin separators, and focused action rows. Preserve
  native phone ergonomics rather than shrinking the desktop layout onto mobile.
- Third-party Bevel, Lucie, WHOOP, and other screenshots are product references,
  not assets or specifications. Reuse the interaction lesson, not their logo,
  trademark, copy, emoji treatment, illustration, or unsupported algorithm.
- Actionable notifications should be concise and contextual when the user has
  allowed visible previews, while hidden-preview content remains generic. Never
  expose raw health values, journal answers, event names, precise location, or
  sensitive interpretations on a protected lock screen.
- Adaptive-day guidance may connect fresh sleep/recovery evidence with a
  locally classified planned workout or availability window. Phrase it as an
  optional adjustment such as keeping the session lighter, and expose the
  evidence behind it; do not imply that calendar access or one short night is a
  medical instruction.

## Metric Truth

- Missing input stays `nil`/not logged. Zero is a measured value only when zero
  is physiologically and semantically valid.
- Every metric has a named source and calculation boundary. Imported,
  wearable-measured, phone-derived, and NOOP-computed values must not be merged
  under misleading provenance.
- Calibration, coverage, stale-data, confidence, and model-population gates are
  product behavior, not optional copy.
- Do not use `ceil` or `floor` to create false precision. Continuous age-like
  values may be shown as years and months only when the model supports that
  interpretation; retain smoothing, minimum-history, bounded-change, and
  uncertainty rules.
- A score change must be explainable from stored inputs and versioned formula
  policy. Formula or provenance changes require parity tests and an operations
  record.

## Body Composition, BMI, And Goals

- Body fat, lean mass, and related composition are useful as source/date-bound
  imported measurements. Do not infer segmental load, muscle, fat, body shape,
  or sex-specific physique from generic band signals.
- BMI is optional adult screening context, not diagnosis, body composition, or
  a universal target. Require confirmed age, height, and weight; suppress it
  outside the supported context.
- A target weight is user-selected. NOOP must not prescribe a deadline, rapid
  loss, calorie restriction, or compensatory exercise. Pregnancy, eating
  disorders, medication, illness, and other clinical contexts require a
  separately reviewed pathway rather than guesswork.
- Movement reminders may support a separately selected activity/step/workout
  goal. Do not turn the difference from a weight target into "walk more" or
  "burn this off" alerts.

## Daily Guidance And Notifications

- Daily guidance may combine fresh, independently supported sleep, recovery,
  effort, self-check, timezone, routine, and generic calendar availability.
  Calendar content must remain local; discard event text after conservative
  classification and never put it on the lock screen.
- Keep interruption controls separate from quiet in-app detection. Defaults are
  off for optional proactive alerts, and permission prompts follow an explicit
  user action.
- One completed sync has one routine-notification budget. Priority and dedupe
  state must be deterministic; reserve before posting, commit only after the OS
  accepts a still-current request, and release on denial, failure, cancellation,
  or stale consent.
- Safety alerts and active-workout cautions are separate from the routine
  budget. They still require bounded delivery, consent, and false-positive
  controls.
- Wind-down, journal, morning recap, hydration, stress/breathe, and workout
  prompts must respect quiet hours, completion state, current evidence,
  cooldowns, opt-out, and private copy.

## Workout Detection And Coaching

- Detection can run after wearable history, HealthKit, or Health Connect
  materializes evidence. It must expose review/undo and avoid silently saving
  low-confidence candidates.
- iOS and Android background execution is opportunistic. A simulator proves
  code and UI, not terminated-app relaunch, OEM behavior, BLE continuity, or
  notification timing.
- Off-wrist sensing, flash/history backfill, haptics, and battery preservation
  may require firmware or vendor SDK behavior. Do not claim software alone
  solves them.
- Workout plans should adapt to the user's selected experience, schedule,
  equipment, constraints, recovery, completed work, and explicit overrides.
  Avoid diagnosis and unsafe progression.
- Exercise animation/video must be correctly mapped, visually legible, free of
  black bars or misleading motion, and supported by rights, redistribution,
  instructional-safety, captions, and reduced-motion evidence. If these are
  unknown, defer shipping the asset.

## Nutrition And Hydration

- Nutrition and hydration entries are user records. Canonical totals and
  editable entries must update transactionally or roll back together.
- Missing intake is "not logged", not zero. Recommendations should not infer
  dehydration, deficiency, or treatment from absent logging.
- Hydration prompts may use user-selected goals and recent logged intake, with
  bounded frequency and an accessible quick-log action. They must not become a
  medical prescription.

## Safety And SOS

- Safety is opt-in paging to accepted contacts with in-app status, optional SMS
  or voice fallback when separately configured, and consented location sharing.
  It is not emergency-service dispatch.
- Automatic fall, medical, or danger inference stays disabled until validated
  hardware, clinical/product policy, false-positive controls, legal review, and
  physical-device evidence exist.
- Precise location is sensitive and ephemeral. Delete the actual persistence
  rows after resolve, cancel, expiry, responder-link expiry, and all-delivery
  failure as defined by the repository contract. Tests must query storage
  directly rather than only checking a redacted response.

## Private Reference Inputs

The owner may provide `/Users/divii/Downloads/noop.json`,
`/Users/divii/Downloads/noop_ref`, screenshots, archives, or exercise media.
Use them only as review context:

- never commit or upload them;
- inventory with bounded metadata;
- do not quote private health data;
- do not treat competitor visuals as proof of algorithms or rights;
- record build/defer/reject decisions in the current operations round.
