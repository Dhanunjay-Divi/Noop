# Restricted Veepoo iOS SDK

The owner-supplied `VeepooBleSDK.framework` is a restricted, static, arm64
iPhoneOS artifact. It is not redistributable through this public repository and
must remain in an approved external `iOS_sdk_source` tree outside the
repository. The configurator accepts that tree through `--sdk-root` or
`NOOP_VEEPOO_IOS_SDK_ROOT`; it defaults to:

```text
~/Downloads/SDK/iOS_Ble_SDK-master/iOS_sdk_source
```

The primary framework is resolved relative to that root at
`Framework/2.2.XX.15/VeepooBleSDK.framework`. Its executable SHA-256 must be:

```text
22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35
```

## Enable a local physical-iPhone build

From the repository root:

```bash
VEEPOO_IOS_SDK_ROOT="<absolute path to the approved iOS_sdk_source directory>"
python3 Tools/local/configure-veepoo-ios-sdk.py \
  --sdk-root "${VEEPOO_IOS_SDK_ROOT}"
python3 Tools/local/configure-veepoo-ios-sdk.py \
  --sdk-root "${VEEPOO_IOS_SDK_ROOT}" \
  --write-config
xcodegen generate
```

The first command verifies the protected manifest, fixed framework bundle,
approved build inputs, framework metadata, module maps, inventories, hashes,
and physical-iPhone architecture. The second reproducibly builds the approved
FMDB and MJExtension dependency products, verifies the complete bundle again,
and atomically writes the gitignored `Config/VeepooLocalSDK.xcconfig`.

Only the `NOOPiOS` target consumes that config. The local values, framework
search paths, supplier link flags, and `NOOP_SUPPLIER_VEEPOO` compilation
condition are qualified with `config=Debug` and `sdk=iphoneos*`. A NOOPiOS
prebuild check rejects changed paths, settings, build inputs, or artifacts
whenever the local SDK is enabled.

Delete `Config/VeepooLocalSDK.xcconfig` to return to the default-off build.

## Updating the supplier SDK

Treat a new framework drop as an adapter replacement:

1. Keep the incoming SDK tree immutable and outside Git.
2. Review its complete inventory, headers, dependencies, hashes, architecture,
   rights, privacy, egress, vulnerabilities, and supported hardware/firmware.
3. Update the protected trust manifest and configurator expectations only
   after that review.
4. Map changed framework APIs only in the private `VeepooBleSDKClient` inside
   `Strand/BLE/VeepooBandAdapter.swift`. Keep
   `VeepooBandSDKClient`, `VeepooBandAdapterControlling`, source coordination,
   registry, storage, metrics, UI, Watch, widgets, and shared packages free of
   supplier types.
5. Update the shared compatibility tuple and wrapper/conformance tests, then
   rerun artifact verification, focused Apple tests, complete Apple builds,
   repository policy gates, and the affected physical-device matrix.

`Tools/tests/test_supplier_sdk_wrapper_boundary.py` fails if the supplier
framework import escapes the native client wrapper.

## Supplier dependency gate

The supplied static framework is not self-contained. The protected trust root
therefore pins the complete approved external build-input tree, fixed vendor
frameworks, and generated FMDB and MJExtension products. The configurator does
not download or copy those inputs into the repository and fails closed on path,
symlink, inventory, digest, platform, or architecture drift.

This permits only a verified local Debug iPhoneOS qualification build.
Redistribution, Release or Archive embedding, signing, installation, and
physical-band behavior remain separate blocked gates.

## Boundaries

- The tool never downloads or copies supplier frameworks into the repository.
- Supplier frameworks, generated dependency products, and the generated config
  remain external or ignored by Git.
- Simulator, macOS, widgets, Watch, shared packages, and clean CI builds do not
  search for, import, verify, or link the framework.
- This wiring does not approve redistribution, medical claims, OTA, Release or
  store distribution, production activation, or physical-band behavior. Those
  remain separate review and hardware-validation gates.
