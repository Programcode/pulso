# Pulso Ingest Protocol — v1

The contract between the Pulso iOS app and any receiving server. It is
deliberately small: a conforming server fits in ~50 lines of any language.
The reference implementation lives in [`server/`](../server/).

v1 is frozen. New *optional* sample fields may be added over time (additive
changes only); anything breaking becomes `/v2/ingest`.

Additive revisions so far:

- **v1.1 (2026-07-12)** — 49 new `type` keys (all listed below), full
  metadata pass-through on workouts, and the workout statistics fields
  (`totalBasalEnergyBurned`, `averageHeartRate`, `minimumHeartRate`,
  `maximumHeartRate`).
- **v1.2 (2026-07-22)** — optional `GET /latest` endpoint so fresh app
  installs skip re-reading history the server already holds.
- **v1.3 (2026-07-27)** — `sexualActivity` type key with the
  `metadata.protectionUsed` boolean.

## Endpoints

### `POST /ingest`

The body is a **JSON array** of elements. Each element is either a **sample
object** or a **tombstone**:

```json
[
  {
    "uuid": "1E9B4C1A-3F2D-4C8E-9B7A-2D5E8F1A6C3B",
    "type": "sleepAnalysis",
    "start": "2026-07-06T01:12:00+01:00",
    "end": "2026-07-06T09:03:00+01:00",
    "value": "asleepREM",
    "source": "Lenilson's Apple Watch",
    "sourceBundleId": "com.apple.health.A1B2C3",
    "metadata": { "timeZone": "Europe/Lisbon" }
  },
  { "deleted": ["A0B1C2D3-...", "E4F5A6B7-..."] }
]
```

Requirements for a conforming server:

- **Accept `Content-Encoding: gzip`.** The app always gzips. (Python:
  `gzip.decompress(body)`; Node: `zlib.gunzipSync(body)`.)
- **Dedupe by `uuid`.** Delivery is at-least-once; re-sending any batch must
  be safe. `uuid` is the idempotency key.
- **Record tombstones.** Elements with a `deleted` key list uuids of samples
  removed from Apple Health (wrong workouts deleted, sleep rewritten, etc.).
  How you apply them is your business; don't lose them.
- **Respond `200` with a JSON object containing `"received": <n>`** (the
  element count). Extra fields are fine — the reference server also returns
  `"new"` and `"deleted"`.
- Auth is optional: if you set a token, require `Authorization: Bearer <token>`
  and reply `401` otherwise. Tailnet-only servers may run open.

Any non-2xx response (or no response) means the app keeps the batch on disk
and retries with exponential backoff (1 min → 1 h cap), in order, forever.
Batches are never dropped and never reordered.

### `GET /health`

Liveness probe; anything `200` passes. Used by the app's "Test Connection"
button.

### `GET /latest` (optional)

Returns a JSON object mapping each stored `type` to the **newest sample
`end` timestamp** the server holds, in the sample's original ISO 8601 form:

```json
{ "sleepAnalysis": "2026-07-15T09:03:00+01:00", "heartRate": "2026-07-15T08:59:12+01:00" }
```

Empty object when the store is empty. Requires the bearer token when one is
configured (same rule as `/ingest`).

Purpose: when the app has no sync cursor for a type (fresh install, newly
enabled type), it asks `/latest` and backfills only from that timestamp
minus a 72-hour safety margin, instead of re-reading and re-sending all
history. Servers compare timestamps in **absolute time** — offsets vary
across the archive, so string comparison picks wrong maxima.

The endpoint is optional: on any non-200 the app falls back to a full
backfill, which the server's uuid dedupe makes safe. Four costs of relying
on it:

- Samples backfilled by a source more than 72 hours late are skipped until
  a manual re-import.
- Deletions older than the catch-up point are not tombstoned.
- The reported timestamps are a high-water mark that never rewinds: if the
  newest samples of a type were later deleted, `/latest` overshoots and
  the catch-up window starts later than the surviving data would suggest.
- The mark is **global, with no device identity**: a second device — or one
  restored from a backup — whose local HealthKit store holds samples the
  server never received will silently skip everything older than the
  cutoff on its first sync (those samples have distinct uuids, so dedupe
  cannot recover them). After restoring a device or pointing an additional
  device at an existing server, run the app's "Re-import Full History"
  once.

The app's "Re-import Full History" always bypasses `/latest`.

## Sample object schema

Optional fields are **omitted** when absent (never `null`). Key order is not
significant.

| Field | Type | Notes |
|---|---|---|
| `uuid` | string | `HKObject.uuid` — the idempotency key |
| `type` | string | One of the type keys below |
| `start` | string | ISO 8601 with UTC offset, second precision |
| `end` | string | Same format; equals `start` for point samples |
| `value` | string \| number | Category name (e.g. `"asleepREM"`) or quantity number; absent for workouts and for categories with no meaningful value (`mindfulSession`) |
| `unit` | string | Only on quantity types; see tables below |
| `source` | string | Name of the writing device/app, verbatim |
| `sourceBundleId` | string | Bundle id of the writing app |
| `metadata` | object | See Metadata below |
| `workoutActivityType` | string | Workouts only, e.g. `"traditionalStrengthTraining"` |
| `duration` | number | Workouts only, seconds |
| `totalEnergyBurned` | number | Workouts only, active kcal |
| `totalBasalEnergyBurned` | number | Workouts only, basal kcal |
| `totalDistance` | number | Workouts only, meters |
| `averageHeartRate` | number | Workouts only, count/min |
| `minimumHeartRate` | number | Workouts only, count/min |
| `maximumHeartRate` | number | Workouts only, count/min |

### Metadata

- **Workouts** carry their sample's full HealthKit metadata dictionary —
  routine names (`HKWorkoutBrandName`), the indoor flag, weather, and
  whatever else the writing app attached. String, number, and boolean values
  pass through as native JSON; other value types (HKQuantity, dates) are
  stringified.
- **`sexualActivity`** samples may additionally carry
  `protectionUsed` (boolean, absent when not recorded — never defaulted).
- **Every other type** carries at most one key: `timeZone`.
- In all cases the `timeZone` key means the sample *recorded* its timezone
  (see Timestamps); HealthKit's raw `HKTimeZone` key is folded into it, never
  duplicated.

### Type keys and units

Percent-unit types deliver human-scale values: `97` under unit `"%"` means
97% (HealthKit's internal 0–1 fractions are converted).

**Sleep & circadian**

| `type` | `value` | `unit` |
|---|---|---|
| `sleepAnalysis` | `inBed`, `awake`, `asleepUnspecified`, `asleepCore`, `asleepDeep`, `asleepREM` | — |
| `timeInDaylight` | number | `min` |
| `appleSleepingWristTemperature` | number | `°C` |
| `appleSleepingBreathingDisturbances` | number | `count` |
| `appleStandHour` | `stood`, `idle` | — |
| `mindfulSession` | — (interval is the data) | — |

**Workouts**

| `type` | `value` | `unit` |
|---|---|---|
| `workout` | — (see workout fields) | — |

**Energy & activity**

| `type` | `value` | `unit` |
|---|---|---|
| `stepCount` | number | `count` |
| `activeEnergyBurned` | number | `kcal` |
| `basalEnergyBurned` | number | `kcal` |
| `physicalEffort` | number | `kcal/hr·kg` |
| `appleExerciseTime` | number | `min` |
| `appleStandTime` | number | `min` |
| `flightsClimbed` | number | `count` |
| `distanceWalkingRunning` | number | `m` |
| `distanceCycling` | number | `m` |
| `distanceSwimming` | number | `m` |
| `swimmingStrokeCount` | number | `count` |

**Cardio & recovery**

| `type` | `value` | `unit` |
|---|---|---|
| `heartRate` | number | `count/min` |
| `restingHeartRate` | number | `count/min` |
| `heartRateVariabilitySDNN` | number | `ms` |
| `vo2Max` | number | `mL/(kg·min)` |
| `heartRateRecoveryOneMinute` | number | `count/min` |
| `walkingHeartRateAverage` | number | `count/min` |
| `oxygenSaturation` | number | `%` |
| `respiratoryRate` | number | `count/min` |

**Body**

| `type` | `value` | `unit` |
|---|---|---|
| `bodyMass` | number | `kg` |
| `bodyFatPercentage` | number | `%` |
| `leanBodyMass` | number | `kg` |
| `bodyMassIndex` | number | `count` |
| `waistCircumference` | number | `cm` |
| `height` | number | `cm` |

**Running & gait**

| `type` | `value` | `unit` |
|---|---|---|
| `runningPower` | number | `W` |
| `runningSpeed` | number | `m/s` |
| `runningStrideLength` | number | `m` |
| `runningVerticalOscillation` | number | `cm` |
| `runningGroundContactTime` | number | `ms` |
| `walkingSpeed` | number | `m/s` |
| `walkingStepLength` | number | `cm` |
| `walkingAsymmetryPercentage` | number | `%` |
| `walkingDoubleSupportPercentage` | number | `%` |
| `appleWalkingSteadiness` | number | `%` |
| `sixMinuteWalkTestDistance` | number | `m` |
| `stairAscentSpeed` | number | `m/s` |
| `stairDescentSpeed` | number | `m/s` |

**Audio exposure**

| `type` | `value` | `unit` |
|---|---|---|
| `environmentalAudioExposure` | number | `dBASPL` |
| `headphoneAudioExposure` | number | `dBASPL` |

**Nutrition**

| `type` | `value` | `unit` |
|---|---|---|
| `dietaryEnergyConsumed` | number | `kcal` |
| `dietaryProtein` | number | `g` |
| `dietaryCarbohydrates` | number | `g` |
| `dietaryFatTotal` | number | `g` |
| `dietaryFiber` | number | `g` |
| `dietarySugar` | number | `g` |
| `dietarySodium` | number | `mg` |
| `dietaryWater` | number | `mL` |
| `dietaryCaffeine` | number | `mg` |
| `numberOfAlcoholicBeverages` | number | `count` |

**Lifestyle**

| `type` | `value` | `unit` |
|---|---|---|
| `sexualActivity` | — (event is the data; see `metadata.protectionUsed`) | — |

Unknown category values serialize as `"value_<n>"`; unknown workout
activities as `"activity_<n>"` — data is never silently merged into "other".

## Timestamps and timezones

Timestamps are **ISO 8601 with the sample's own UTC offset — never
normalized to UTC**. Apple's own `export.xml` stamps all history with the
export-time offset, destroying original timezones; Pulso does not repeat
that mistake.

- If the sample recorded a timezone (`HKMetadataKeyTimeZone`), its offset is
  used **and** `metadata.timeZone` carries the zone identifier.
- Otherwise the device's timezone at sync time is used and `metadata` is
  **absent** — so consumers can distinguish a recorded timezone from an
  assumed one.

## Delivery semantics

- Batches are at most 5,000 samples / ~2 MB gzipped.
- Order: batches arrive in the order the app read them (FIFO per queue).
- At-least-once: duplicates are possible (crash between upload and local
  bookkeeping); the `uuid` dedupe rule makes the stream effectively
  exactly-once.
- Sources are **not** merged client-side: Apple Watch, WHOOP, AutoSleep etc.
  each deliver their own overlapping records, faithfully attributed via
  `source`. Merging is analysis-side policy, not transport policy.

## Reference server storage (informative)

The reference server appends each element to `data/<type>.ndjson` (tombstones
to `data/_deleted.ndjson`), one JSON object per line, adding a `receivedAt`
field with the server's local time. Inspect with `cat`, `jq`, or anything
that reads lines.

---

# v2 (this fork): every HealthKit type, several destinations

v2 keeps v1's sample object and adds to it; everything above still holds
for a "Pulso server" destination, which sends exactly the v1 body.

## Request bodies

Each destination picks one of three bodies for a batch:

- **pulso.v2 envelope** (HTTPS / webhook default, and Home Assistant):

  ```json
  {
    "schema": "pulso.v2",
    "batchId": "6F1C…",
    "type": "heartRate",
    "createdAt": "2026-10-22T08:00:03Z",
    "sentAt": "2026-10-22T08:00:04Z",
    "device": {"id": "<identifierForVendor>", "name": "iPhone", "model": "iPhone",
               "systemVersion": "26.1", "appVersion": "0.1.0 (12)", "bundleId": "com.programcode.pulso"},
    "items": [ <sample objects and tombstones, as in v1> ]
  }
  ```

  A test request (the Test button) is `{"schema": "pulso.v2", "test": true,
  "items": [], …}`; receivers should accept it and store nothing.

- **Bare array**: the v1 body.
- **NDJSON**: one item per line (also what file export writes).

`type` names the type the batch was read for; items carry their own `type`
too. Batches hold one type, except snapshot batches.

## Headers

- `Content-Encoding: gzip` when the destination has gzip on (default for
  HTTPS; off for Home Assistant).
- `Authorization: Bearer <token>` when a token is set.
- `X-Signature: sha256=<hex>` when an HMAC secret is set: HMAC-SHA256 of the
  request body **exactly as sent** (after gzip), keyed with the secret.
- `X-Pulso-Batch: <batchId>` and `X-Pulso-Type: <type>` on every batch.
- Any custom headers configured on the destination.

Success is any 2xx. Anything else, or no response, keeps the batch queued
and retries with exponential backoff (1 min → 1 h).

## Additional sample fields

All optional, omitted when absent.

| Field | Notes |
|---|---|
| `kind` | `quantity`, `category`, `workout`, `route`, `heartbeatSeries`, `electrocardiogram`, `audiogram`, `stateOfMind`, `scoredAssessment`, `visionPrescription`, `medicationDoseEvent`, `correlation`, `characteristics`, `activitySummary`, `medication` |
| `sourceVersion`, `sourceProductType`, `sourceOSVersion` | from `HKSourceRevision` |
| `device` | the `HKDevice` fields that are set: `name`, `manufacturer`, `model`, `hardwareVersion`, `firmwareVersion`, `softwareVersion`, `localIdentifier`, `udiDeviceIdentifier` |
| `metadata` | now the sample's **full** HealthKit metadata for every type (v1 sent it only for workouts). `timeZone` and `protectionUsed` are still folded in as in v1. Nested values pass through as JSON arrays/objects. |
| `details` | type-specific structure, below |

## Type keys and units

Every quantity, category and characteristic identifier in the iOS SDK the
app was built with is synced. The key is the identifier without its prefix,
in lower camel case (`HKQuantityTypeIdentifierVO2Max` → `vo2Max`). The list
is generated from the SDK headers by `scripts/gen_healthkit_catalog.py`;
Settings → Coverage on the phone shows what this build syncs and what it
skips, with the reason.

Units: the 58 v1.1 types keep their v1.1 units (tables above). Every other
quantity uses the canonical unit HealthKit's headers name for it (`%`
values are still scaled to 0–100, and `count/s` is sent as `count/min`).
Category values are the Swift case names of the SDK's value enum
(`HKCategoryValueSeverity.moderate` → `"moderate"`), `value_<n>` for ones
the build doesn't know.

Other type keys: `workout`, `workoutRoute`, `heartbeatSeries`,
`electrocardiogram`, `audiogram`, `stateOfMind` (iOS 18+), `gad7`, `phq9`
(iOS 18+), `visionPrescription`, `medicationDoseEvent` (iOS 26+),
`bloodPressure` and `food` (correlations), and the snapshot types
`characteristics`, `activitySummary`, `medication` (iOS 26+).

## `details` by kind

- **quantity**: for series samples, `count` and (discrete types) `minimum`,
  `maximum`, `average`, `mostRecent`, in the sample's unit.
- **workout**: `events` (`type`, `start`, `end`, `duration`, `metadata`),
  `activities` (multisport segments: `uuid`, `activityType`, `locationType`,
  `swimmingLocationType`, `lapLengthMeters`, `start`, `end`, `duration`,
  `metadata`, `events`, `statistics`), `statistics` (per type key: `unit`,
  `sum`, `average`, `minimum`, `maximum`, `mostRecent`), `routeUUIDs`,
  `heartRateSampleUUIDs` and `heartRateLink` (`associated` when the recording
  app tied the samples to the workout, `timeRange` when they were matched by
  time). The v1 workout fields are unchanged.
- **route** (`workoutRoute`): `locationFields` names the columns of
  `locations`, each a row `[secondsFromStart, latitude, longitude, altitude,
  horizontalAccuracy, verticalAccuracy, speed, course, speedAccuracy,
  courseAccuracy]`; `workoutUUID` when the parent workout was found.
- **heartbeatSeries**: `beats` rows `[secondsFromStart, precededByGap]`.
- **electrocardiogram**: `classification`, `symptomsStatus`,
  `averageHeartRate`, `samplingFrequencyHz`, `numberOfVoltageMeasurements`,
  `lead`, `voltages` rows `[secondsFromStart, microvolts]`.
- **audiogram**: `points`, each with `frequencyHz` and `tests` (`side`,
  `conductionType`, `masked`, `sensitivityDBHL`, clamping range) on iOS
  18.1+, or `leftEarDBHL` / `rightEarDBHL` before.
- **stateOfMind**: `kind`, `valence`, `valenceClassification`, `labels`,
  `associations`.
- **scoredAssessment** (`gad7`, `phq9`): `score` (also the `value`), `risk`,
  `answers`.
- **visionPrescription**: `prescriptionType`, `dateIssued`, `expirationDate`,
  `rightEye` / `leftEye` (sphere, cylinder, axis, add power, vertex and
  pupillary distances, prism; contacts: base curve, diameter), `brand`.
- **medicationDoseEvent**: `logStatus`, `scheduleType`, `scheduledDate`,
  `doseQuantity`, `scheduledDoseQuantity`, `unit`, `medicationConcept`, and
  `medicationName` / `medicationNickname` when the medication is shared.
- **correlation**: `objects`, the member samples' `uuid`, `type`, `value`,
  `unit` (the members are also sent as their own samples).

## Snapshots

Characteristics, daily activity summaries and the medication list have no
sync cursor, so they are sent as records with stable ids, and only when
their content changes:

- `characteristics` (uuid `characteristics`): `details` holds
  `dateOfBirth`, `biologicalSex`, `bloodType`, `fitzpatrickSkinType`,
  `wheelchairUse`, `activityMoveMode`.
- `activitySummary` (uuid `activitySummary-YYYY-MM-DD`, start/end = that
  day): move, exercise and stand values with their goals, `activityMoveMode`,
  `paused`. The first read covers all history; later reads re-check the
  last 35 days.
- `medication` (uuid `medication-<concept key>`): `displayText`, `nickname`,
  `generalForm`, `isArchived`, `hasSchedule`, `relatedCodings`.

Receivers should upsert by uuid.

## Deletions

Tombstones are unchanged: `{"deleted": [uuids]}`.

## Other destinations

- **MQTT**: QoS 1. Each batch publishes one JSON array (bare-array form) per
  type to `<prefix>/<type>`, and tombstones to `<prefix>/deleted`. The Test
  button publishes an envelope to `<prefix>/test`.
- **Home Assistant**: the envelope, uncompressed, at most 200 items per
  request, with arrays longer than 50 entries in `details` replaced by
  `<name>Count`.
- **File export**: NDJSON lines appended to `pulso-YYYY-MM-DD.ndjson` (the
  day of export) in the chosen folder.
