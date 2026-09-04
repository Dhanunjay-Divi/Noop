# NOOP+ Managed Storage Synthetic Policy

This policy is for synthetic staging only. It does not authorize uploading real
health data or enrolling production users.

NOOP remains usable without an account. Local collection, metrics, coaching,
workouts, journal, automations, export, and device control are not restricted by
this managed-storage option.

NOOP+ managed storage is optional. When a tester explicitly enrolls, the app may
upload only the data classes selected on the consent screen. The service stores
immutable compressed chunks, encrypted backup objects, account and device
control records, sync cursors, and derived summaries according to the retention
rules returned during enrollment.

Client-encrypted backup data cannot be read by the service. Server-readable
sync data is a separate selection used for restore, multi-device history, and
server-side summaries. Neither path makes NOOP a medical device.

The tester can disconnect without deleting local data, export managed data, or
request managed-data erasure. Cloud deletion is asynchronous and includes
object storage, database records, caches, analytics copies, and eligible
backups; narrowly scoped replay-prevention tombstones may remain until their
stated expiry.

Background transfer is best effort on iOS and Android. The phone writes locally
first, retries resumably, and shows freshness honestly. Cloud storage does not
prevent operating-system suspension, Bluetooth interruption, or wearable
disconnects.
