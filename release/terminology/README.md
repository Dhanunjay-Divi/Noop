# Legacy terminology inventory

`Tools/terminology-audit.py` classifies every tracked legacy-name occurrence as
customer, core, persisted, import, compatibility, legal, fixture, generated, or
historical.

The inventory stores paths, categories, counts, line numbers, token counts, and
digests, but no copied source lines. The active allowlist is a fail-closed
ratchet: changed or new customer/core usage requires review and an explicit
snapshot update. Persisted IDs and truthful import/legal provenance are not
rewritten.

Run:

```sh
python3 Tools/terminology-audit.py check
```

After a reviewed migration:

```sh
python3 Tools/terminology-audit.py snapshot
```
