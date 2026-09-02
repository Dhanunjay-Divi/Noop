# Attribution

NOOP is an independent, unofficial, local-first app for macOS, Android, and iOS.
It is not affiliated with, endorsed by, or connected to any supported wearable
manufacturer. Third-party marks identify compatible hardware only.

## NOOP source

The NOOP-controlled source and contributions in this repository are owned or
controlled by the NOOP repository owner and distributed under the repository's
PolyForm Noncommercial License 1.0.0. The dated owner authorization is recorded in
[`docs/provenance/OWNER-RIGHTS-DECLARATION.md`](docs/provenance/OWNER-RIGHTS-DECLARATION.md).

NOOP's device protocol, storage, analytics, Apple, Android, and self-hosted
service implementations are maintained in this canonical repository. Protocol
compatibility is based on observed wire behavior and public interoperability
facts. NOOP does not intentionally copy or redistribute a manufacturer's app
source, firmware, binaries, credentials, logos, or assets.

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Oura ring (gen 3/4/5) protocol
NOOP's Oura code is **original clean-room** work. The local BLE source
(`Strand/BLE/OuraLiveSource.swift` + `android/.../ble/OuraLiveSource.kt`) and the JVM/Swift-pure
`OuraProtocol` package (`Packages/OuraProtocol/`, `android/.../com/noop/oura/`) were written from
**documented protocol facts only**, cited tersely in `docs/OURA_PROTOCOL.md`. The community
reverse-engineering resources below were consulted as **facts-only references** (byte layouts,
service/characteristic UUIDs, framing and auth shapes); **no RE source code is copied** into NOOP.
- **`open_ring`**: consulted for protocol facts only. Licensed **GPL-3.0**; NOOP copies none of
  its code and is not a derivative work of it.
- **`open_oura`**, **`ringverse`**, **`relue`**: consulted for protocol facts only. These carry
  **no license**, so NOOP treats them as reference documentation of observed behaviour only and
  copies no code from them.

NOOP reads only the ring's own decoded raw signals and its own open event tags, computes NOOP's
own Charge/Rest, and **never** reads or displays Oura's encrypted readiness or sleep scores. The
documented Oura file-import lane (`Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`)
remains available as a fallback.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).
- **Lucide** (`lucide-icons/lucide`) — supplies controls in the strength media QA
  viewer used by the asset validation tool. ISC License; portions derived from
  Feather are MIT licensed.
- **Coil** (`coil-kt/coil`) — decodes and caches exercise GIF and anatomy SVG media
  in the Android Strength Trainer. Apache License 2.0.
- **ExerciseDB V1 / AscendAPI** — NOOP maps its own exercise identifiers to
  animated media loaded at runtime from `static.exercisedb.dev`.
  The media is not copied into this repository or either app bundle and remains
  subject to its provider's terms. The in-viewer attribution links to AscendAPI;
  details are recorded in `Tools/StrengthMotion/ASSET-PROVENANCE.md`.
- **Open-Meteo** — supplies opt-in current conditions on Android after the user
  grants approximate location access. NOOP sends a coordinate rounded to two
  decimal places, stores no location history, and links attribution from the
  weather details view.
- **MuscleMap body geometry** (`melihcolpan/MuscleMap`) — supplies the anatomical
  SVG path geometry used by NOOP's interactive strength load and recovery map.
  The path data was converted from MuscleMap's Swift source by openGym and is
  used under the MIT License. NOOP's renderer and interaction code are original.

The complete resolved runtime dependency inventory and required license texts
are generated into [`NOTICE`](NOTICE). Those independent dependencies remain
under their own licenses and are not relicensed by NOOP.

NOOP contains no supported manufacturer's proprietary app code, binaries,
firmware, logos, or assets and performs no DRM circumvention. It operates only
with the user's own device and data. NOOP is **not a medical device**; all
metrics are approximations and not clinically validated.
