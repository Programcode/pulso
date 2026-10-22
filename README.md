<p align="center">
  <img src="docs/icon.png" width="128" alt="Pulso app icon — an ECG snap electrode">
</p>

<h1 align="center">Pulso</h1>

<p align="center"><strong>Continuously deliver your Apple Health data to a server you own.</strong></p>

> **This fork** ([Programcode/pulso](https://github.com/Programcode/pulso), from
> [lenilsonjr/pulso](https://github.com/lenilsonjr/pulso)) reads every
> HealthKit type the iOS SDK lets a third-party app read — the type list is
> generated from the SDK headers at build time — and sends it to several
> destinations at once: HTTPS/webhooks (gzip, custom headers, bearer token,
> HMAC signature), the original Pulso protocol, Home Assistant, MQTT, and
> NDJSON files. It adds Shortcuts actions and ships as an unsigned IPA built
> by GitHub Actions. The wire format is documented in
> [`docs/PROTOCOL.md`](docs/PROTOCOL.md) (v2 section).

Pulso is an open-source iOS app with one job: read the Apple Health data you
select and ship it — incrementally, in the background, surviving crashes and
outages — to an HTTP endpoint you configure. Self-hosted personal telemetry.

<p align="center">
  <img src="docs/screenshots/status.png" width="300" alt="Status screen: per-type sync state and Sync Now">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings.png" width="300" alt="Settings screen: server endpoint, bearer token, per-type toggles">
</p>

## Privacy model (read this first)

- All data flows **device → your server**. There is no cloud, no account, no
  analytics, no telemetry, and no third-party code (zero dependencies).
- The app talks only to the destinations you configure: it POSTs batches
  (or publishes them over MQTT, or writes files), sends a test request when
  you tap Test, and, if a destination has catch-up enabled, asks its
  `/latest` what it already holds. Nothing else, ever.
- Pending data on the device is excluded from device backups.
- Bearer tokens, HMAC secrets and MQTT passwords are stored in the iOS Keychain.

## Why it exists

Apple Health has no API. The data lives in an encrypted on-device store that
only a native iOS app can read, with per-type user consent. One-shot exports
are manual, huge, and instantly stale; Shortcuts can't read workouts at all
and takes tens of minutes for a few thousand samples. If you want your sleep
and workouts available to your own tools (say, AI agents on your Mac)
continuously, a dedicated app is the only honest path. This is that app.

## How it works

```
HealthKit ──anchored queries──► SyncEngine ──batches──► Outbox (disk) ──HTTP──► your server
                 ▲                                          │
   observer / BGTask / foreground triggers            retry w/ backoff
```

- **Anchored queries** (`HKAnchoredObjectQuery`) are the sync cursor: each
  pass returns exactly the new samples and deletions since the last anchor —
  rewrites and late backfills from other apps included.
- **The outbox** writes every batch to disk *before* the first upload
  attempt and deletes it only on a server 2xx. **The anchor advances only
  when the server ACKs.** Crash anywhere and the worst case is a re-send,
  which the server dedupes by sample uuid.
- **Triggers**: HealthKit background delivery (immediate for sleep and
  workouts, hourly for the rest), an opportunistic `BGAppRefreshTask`, and a
  full sync every time you open the app.

**Honest expectations:** iOS does not run daemons, and health data is
unreadable while the phone is locked. In practice, sleep data lands on your
server within minutes of picking up the phone in the morning. That is the
ceiling on iOS, and it's good enough.

### Synced types

Everything the iOS SDK declares that a third-party app can read, on the iOS
the phone runs (iOS 17+): about 120 quantity types, 70 category types
(symptoms, cycle tracking, sleep stages, events…), workouts (with events,
multisport activities, all statistics and links to their routes and
heart-rate samples), workout routes with GPS points, heartbeat series, ECGs
with voltages, audiograms, state of mind and GAD-7/PHQ-9 (iOS 18), vision
prescriptions, medication doses and the medication list (iOS 26), blood
pressure and food correlations, characteristics (birth date, sex, blood
type, skin type, wheelchair use, move mode) and daily activity rings.

[`scripts/gen_healthkit_catalog.py`](scripts/gen_healthkit_catalog.py)
generates [`HealthKitCatalog.generated.swift`](Pulso/Health/HealthKitCatalog.generated.swift)
from the SDK's HealthKit headers; CI regenerates it before every IPA build,
so a newer Xcode brings its new types along. Settings → Coverage on the
phone lists what this build syncs and what it skips, with the reason.

Not synced: clinical records (FHIR) and CDA documents. Both need the
`health-records` entitlement plus per-record approval, which re-signing
certificates generally can't grant; HealthKit itself withholds a few
identifiers (shown in Coverage).

Every type can be toggled in Settings (all on by default). Vision
prescriptions and medications are shared item by item: tap their buttons
under Settings → Health Access.

### Destinations

Settings → Destinations. Several can be enabled; each has its own durable
queue and retry backoff, and a batch is deleted from a queue only after
that destination accepted it.

- **HTTPS / webhook** — POSTs the pulso.v2 envelope (or a bare array, or
  NDJSON), gzip optional, custom headers, `Authorization: Bearer`, and with
  an HMAC secret `X-Signature: sha256=<hex>` over the body as sent.
- **Pulso server** — the original protocol, for the Rust reference server.
- **Home Assistant webhook** — the envelope, small batches, long series
  reduced to their length.
- **MQTT** — QoS 1, one JSON message per type per batch on `<prefix>/<type>`.
- **File export** — NDJSON appended to `pulso-<date>.ndjson` in the app's
  folder (Files → On My iPhone → Pulso) or a folder you pick, e.g. in
  iCloud Drive.

### Shortcuts

- **Sync Health Data** — optional types; with a date range it re-sends that
  period.
- **Backfill Health Data** — re-sends history (optionally since a date) for
  some or all types; opens the app so it can run long.
- **Get Last Sync Status** — returns a text summary: last sync, what was
  sent, what is queued per destination.

Run them from Personal Automations at fixed times. HealthKit is only
readable while the phone is unlocked, so a sync that fires while it is
locked does nothing until the next one.

## Quick start

### 1. Run a server

Anything that speaks [the protocol](docs/PROTOCOL.md) works. The reference
server is a single Rust binary that appends NDJSON to disk:

```sh
cargo build --release                             # binary: target/release/pulso-server
PULSO_TOKEN=secret PULSO_BIND=0.0.0.0 target/release/pulso-server   # port 8787, ./data
```

or with Docker:

```sh
docker build -t pulso-server server/
docker run -p 8787:8787 -v pulso-data:/data pulso-server
```

Your data ends up in `data/<type>.ndjson` — one JSON object per line,
inspectable with `cat`.

### 2. Install the app

**Unsigned IPA (this fork):** every push to `main` builds
`Pulso-<version>-<build>-unsigned.ipa` in GitHub Actions (artifact
*Pulso-unsigned-ipa*); a `v*` tag also attaches it to a GitHub Release.
Re-sign it with your own certificate (Signulous, AltStore, …). The binary
carries the HealthKit and HealthKit background-delivery entitlements; your
provisioning profile must allow them. The bundle id is
`com.programcode.pulso` unless you set the `PULSO_BUNDLE_ID` repository
variable or pass `bundle_id` when running the workflow by hand.

**From source:** open `Pulso.xcodeproj` in Xcode 26+, select the **Pulso**
target → Signing & Capabilities, pick your team, and run on your iPhone
(iOS 17+).

- **Free Apple ID:** works, but apps expire after 7 days and must be
  re-installed from Xcode.
- **Paid developer account:** 1-year signing, plus TestFlight if you want
  install-over-the-air.
- App Store distribution is possible but brings review requirements
  (privacy policy URL, etc.) — out of scope here.

### 3. Configure and sync

In the app: Settings → Add Destination → enter its URL and credentials →
Test → Status → Grant Health Access → Sync Now. An existing Pulso install
keeps its server as a "Pulso server" destination.

The first sync imports your full history (can be 100k+ samples — keep the
app open and unlocked; a progress note shows in Status). It ships in 5,000-
sample chunks and saves progress continuously, so interrupting it is safe.
After that, everything is incremental and automatic.

## Tailscale and plain HTTP

Pulso is built with a tailnet in mind: the endpoint is typically a
`100.x.y.z` address reachable only inside your WireGuard-encrypted network.
Because raw IPs can't get TLS certificates, the app sets ATS
`NSAllowsArbitraryLoads` to permit plain HTTP — the tailnet already encrypts
the wire. If you point Pulso at a server across the open internet instead,
use HTTPS.

## FAQ

**A type shows "No data yet" — is permission missing or is there no data?**
iOS won't tell (by design: read-permission status is invisible to apps).
Check the Health app → Profile → Apps → Pulso. This is why the UI treats
both states as one.

**I see overlapping sleep records from Watch, WHOOP, and AutoSleep.**
By design. Pulso delivers every source faithfully with `source` attribution
and never merges — dedupe/merge policy belongs to your analysis, not your
transport.

**What about deleted samples?**
Anchored queries surface deletions; Pulso ships them as tombstones
(`{"deleted": [uuids]}`) and the reference server records them in
`_deleted.ndjson`.

**I restored my phone from a backup / added a second device — is my data complete?**
Run Settings → Re-import Full History once. Fresh installs normally skip
history the server already has (via `GET /latest`), but that check has no
per-device awareness — samples that only exist on the "new" device and
predate the server's newest data would otherwise be skipped.

**Workout GPS routes? ECG?**
Both synced in this fork (see `details` in the v2 protocol). Writing data
back to Health is out of scope.

## Repository layout

```
Pulso/            the iOS app (SwiftUI, zero dependencies)
PulsoTests/       unit tests (serializers, outbox state machine, gzip, wire format)
server/           reference receiver (Rust) + Dockerfile
docs/PROTOCOL.md  the versioned app↔server contract
```

## License

MIT — see [LICENSE](LICENSE).
