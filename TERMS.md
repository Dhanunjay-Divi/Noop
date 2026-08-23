# NOOP — Terms of Use & Acknowledgment

**Version 2.3**

> **This is not legal advice.** This document was drafted with the help of an AI tool, not a lawyer.
> It is offered honestly and in good faith, but the NOOP maintainers are not lawyers and nothing here
> is a legal opinion. Before relying on these terms as *binding*, have them reviewed by a qualified
> lawyer in your own jurisdiction. Some of what follows may not be enforceable, and the law in many
> places limits what *anyone* is allowed to disclaim (see §6).

By installing or using NOOP — and by ticking the box on first launch — **you confirm that you have
read, understood, and accept the points below.** If you do not accept them, do not use NOOP, and
remove it.

---

## 1. What NOOP is — and who provides it

This reference NOOP codebase is an unofficial, non-commercial, local-first application for macOS, Android and iOS
that can read supported wearables and health stores. Its core database stays on your device by default;
NOOP does not require a NOOP account or automatic NOOP-operated cloud storage.

The current source and builds are licensed only for permitted non-commercial
purposes under `LICENSE` and are not cleared for commercial distribution. A
future commercial NOOP product must come from independently authored or
separately licensed code and will publish its own reviewed terms.

**NOOP Band is in development and is not available yet.** Until NOOP Band is announced ready,
current direct-band support interoperates with compatible third-party WHOOP hardware owned by the
user. The app will identify NOOP Band explicitly when first-party hardware support is ready.

Some features deliberately send selected data to a destination you enable or invoke. These include a
self-hosted server, Friends sharing, Oura import, an AI provider, Apple Health, and files or share-sheet
exports. Each destination has its own operator and privacy terms. Review its screen before enabling it;
do not configure a destination you do not trust. The maintainers cannot promise that an external
destination will handle data as NOOP's local store does.

NOOP is currently maintained by its project maintainers and contributors, referred to throughout as
**"the maintainers."** "You" means the individual or entity using NOOP.

## 2. Current third-party hardware compatibility

NOOP is developed independently of WHOOP, Inc. It is **not affiliated with, endorsed by, sponsored by, or connected
to WHOOP, Inc. in any way.** "WHOOP" is a trademark of WHOOP, Inc., used here only
**descriptively (nominative fair use)** to identify the third-party hardware NOOP interoperates with —
never to suggest origin, sponsorship, or endorsement, and never as NOOP's own brand. All other
trademarks belong to their respective owners.

## 3. Use at your own risk — and the WHOOP Terms of Service

While current third-party band support is active, you may use NOOP **only with a compatible WHOOP
device you own**, to read **your own data.**

**Using NOOP may breach WHOOP's Terms of Service.** Whether to use NOOP, and any consequences for
your WHOOP account, subscription, device, or warranty, are **your responsibility and your decision
alone.** NOOP does not require or encourage you to break any agreement you have entered into; how you
use hardware you own is up to you. You are responsible for reviewing the agreements and laws that
apply to you, and for your own compliance with them.

You accept that NOOP is **experimental software that talks to your device's firmware over an
unofficial, reverse-engineered protocol.** As with any such tool, there is a residual risk to the
device, its data, and its connection to official services. **You assume that risk.**

## 4. Source provenance and proprietary material

NOOP does not intentionally bundle WHOOP application binaries, firmware, logos, artwork, credentials,
or extracted proprietary source. Protocol interoperability work is based on observed wire behavior and
community research. Parts of the protocol, storage, and collection lineage were adapted from earlier
community repositories; `ATTRIBUTION.md`, `NOTICE`, and `docs/REFERENCE_REPOSITORY_AUDIT.md` record
that lineage. One inherited source lineage does not currently carry an explicit upstream software
license. Attribution is not permission, and clean redistribution rights for that expression must not be
claimed unless written permission is obtained or the affected code is independently replaced.

## 5. Not a medical device

NOOP is **not a medical device** and provides **no medical advice.** Heart rate, HRV, recovery,
strain, sleep stages, SpO₂, respiratory rate, skin temperature, and every other derived metric are
**approximations** computed from published methods. They are **not clinically validated.**

**Do not use NOOP to diagnose, treat, monitor, or make any decision about a health condition.** NOOP
is for general wellness, personal interest, and educational use only. It is not intended to diagnose,
treat, cure, or prevent any disease or condition. **Always consult a qualified healthcare
professional**, and seek emergency care for any medical concern — do not rely on NOOP.

This covers **every** feature. A few in particular:

- **Mind / mood check-in.** The daily mood check-in, and any correlation NOOP draws between your
  mood and your other metrics, is **personal self-tracking and informational only.** It is **not** a
  mental-health assessment, diagnosis, screening, therapy, or treatment, and it is **not** a
  substitute for professional care. **If you are struggling or in crisis, contact a qualified
  professional or your local emergency service immediately — do not rely on NOOP.**
- **Nutrition import.** Importing nutrition data (e.g. a Cronometer or MacroFactor CSV) only displays
  figures **you** recorded elsewhere. It is **informational only** and is **not dietary,
  nutritional, or medical advice.**
- **Apple Health / "Export for Shortcuts" (iOS).** After you explicitly enable Apple Health permissions,
  NOOP may read authorized categories and may automatically write or update NOOP-authored samples during
  foreground or background sync. You can review or revoke access in Apple Health. NOOP manages only the
  samples it authored; it does not control samples written by other apps. The separate HealthKit-free
  "Export for Shortcuts" path runs when you invoke and share it. **You are responsible for the data you
  authorize or push into Apple Health** and for whatever you or a Shortcut does with it afterwards. The
  values are the same uncertified approximations described above.

## 6. Warranty and liability — honestly stated

NOOP is provided **"as is" and "as available", with no warranty or condition of any kind**, express or
implied (including, as far as the law allows, any implied warranties of satisfactory quality, fitness
for a particular purpose, accuracy, or non-infringement).

**To the maximum extent permitted by applicable law**, the maintainers will not be liable to you for
any loss or damage arising out of these terms, or out of the use, misuse, or nature of NOOP —
including loss of or inaccurate data, device problems, loss of warranty or service, or any indirect
or consequential loss — under any kind of legal claim, even if advised of the possibility.

**Nothing in these terms excludes or limits any liability that cannot be excluded or limited under the
law that applies to you** — for example, liability for death or personal injury caused by negligence,
or for fraud. Where a limitation above is not permitted by your local law, it applies only to the
fullest extent that law allows, and the rest of these terms remain in effect.

Because this is early-access software distributed on a non-commercial basis and
the third-party interoperability path is clearly disclosed,
you accept that this allocation of risk is reasonable.

## 7. Your acknowledgment

On first launch (and again if these terms materially change), NOOP asks you to confirm several
statements **individually** before you can continue. By ticking each box you confirm that:

- **you understand NOOP Band is not available yet, this version currently connects to compatible
  WHOOP hardware you own, and you will use only your own band and your own data;**
- **you understand NOOP is early-access wellness software, provided "as is", and is not a medical
  device or medical advice;** and
- **you have read and accept these Terms of Use, including the warranty and liability limits allowed
  by law.**

You also confirm that you have read and accept §1–§6. NOOP records, on your device, the version you
accepted and when — a local record of your acknowledgment. If these terms change in a way that
materially affects your rights, NOOP will ask you to acknowledge the new version.

## 8. Product transition and third-party independence

NOOP Band is planned as NOOP's own product. Until it is announced ready, references to supported
direct-band hardware describe third-party WHOOP devices. Nothing in NOOP suggests that the app or its
planned hardware originates from, is sponsored by, or is endorsed by WHOOP. Current interoperability
exists to let people read their own device's data on their own device; it is not intended to disrupt
or damage third-party products or services.

## 9. Changes, governing law, and severance

The maintainers may update these terms; the current version ships with the app and is shown on first
launch (and again if it materially changes). Continuing to use NOOP after a change means you accept
the updated terms.

**These terms are governed by the laws of the country in which you reside,** and any dispute is
subject to the courts of that country. This preserves your local consumer protections and names no
other jurisdiction.

If any part of these terms is found unenforceable, that part is severed and the rest continues to
apply. A failure to enforce any part is not a waiver of it.

---

*This NOOP build is non-commercial, local-first, and independent of WHOOP, Inc. Thank you for
using it responsibly. See also `LICENSE` (PolyForm Noncommercial) and
`DISCLAIMER.md`.*
