# Restricted Veepoo iOS SDK

The owner-supplied `VeepooBleSDK.framework` is a restricted, static, arm64
iPhoneOS artifact. It is not redistributable through this public repository and
must remain at:

```text
/Users/divii/Downloads/SDK/iOS_Ble_SDK-master/iOS_sdk_source/Framework/2.2.XX.15/VeepooBleSDK.framework
```

Its executable SHA-256 must be:

```text
22e9d0154c5fecddbd3a21ef309fb3d33d734ec5f8e671787fa9ee8564d13d35
```

## Enable a local physical-iPhone build

From the repository root:

```bash
python3 Tools/local/configure-veepoo-ios-sdk.py
python3 Tools/local/configure-veepoo-ios-sdk.py --write-config
xcodegen generate
```

The first command verifies the fixed path, digest, framework metadata, module
map, and single `arm64` slice. The second repeats verification before atomically
writing the gitignored `Config/VeepooLocalSDK.xcconfig`.

Only the `NOOPiOS` target consumes that config. The local values, framework
search path, `-ObjC -framework VeepooBleSDK` link flags, and
`NOOP_SUPPLIER_VEEPOO` compilation condition are all qualified with
`sdk=iphoneos*`. A NOOPiOS prebuild check rejects changed paths, settings, or
artifacts whenever the local SDK is enabled.

Delete `Config/VeepooLocalSDK.xcconfig` to return to the default-off build.

## Supplier dependency gate

The supplied static framework is not self-contained. A bounded iPhoneOS link
probe found auto-linked FMDB, MJExtension, ABParTool, JL, ZipZap, and related
vendor dependencies that are not part of the approved artifact above. This
wiring deliberately does not download, copy, or trust those unpinned
dependencies. An adapter-enabled physical build remains blocked until the
supplier dependency bundle has approved rights, versions, hashes, and a
separate restricted intake path.

## Boundaries

- The tool never downloads or copies the framework.
- `VeepooBleSDK.framework` and the generated config are ignored by Git.
- Simulator, macOS, widgets, Watch, shared packages, and clean CI builds do not
  search for, import, verify, or link the framework.
- This wiring does not approve redistribution, medical claims, OTA, production
  activation, or physical-band behavior. Those remain separate review and
  hardware-validation gates.
