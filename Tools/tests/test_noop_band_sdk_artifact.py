from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Tools" / "verify-noop-band-sdk-artifact.py"
SPEC = importlib.util.spec_from_file_location("noop_band_sdk_verifier", MODULE_PATH)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class NoopBandSDKArtifactTest(unittest.TestCase):
    def test_checked_in_artifact_is_exact(self) -> None:
        result = VERIFIER.verify_artifact(ROOT / "Vendor" / "NoopBandSDK")
        self.assertEqual(10, result["files"])
        self.assertFalse(result["supplierArtifactsIncluded"])

    def test_tampered_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary).resolve() / "artifact"
            shutil.copytree(ROOT / "Vendor" / "NoopBandSDK", copied)
            source = copied / "production" / "apple" / "NoopBandModels.swift"
            source.write_bytes(source.read_bytes() + b"\n")
            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "size mismatch",
            ):
                VERIFIER.verify_artifact(copied)

    def test_tampered_package_definition_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary).resolve() / "artifact"
            shutil.copytree(ROOT / "Vendor" / "NoopBandSDK", copied)
            package = copied / "Package.swift"
            package.write_bytes(package.read_bytes() + b"\n")
            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "integration wrapper digest mismatch",
            ):
                VERIFIER.verify_artifact(copied)

    def test_unmanifested_top_level_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary).resolve() / "artifact"
            shutil.copytree(ROOT / "Vendor" / "NoopBandSDK", copied)
            (copied / "Unexpected.swift").write_text(
                "fatalError(\"must not compile\")\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "top-level layout is not exact",
            ):
                VERIFIER.verify_artifact(copied)

    def test_supplier_binary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            copied = Path(temporary).resolve() / "artifact"
            shutil.copytree(ROOT / "Vendor" / "NoopBandSDK", copied)
            (copied / "supplier.aar").write_bytes(b"synthetic")
            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "binary or archive payload is forbidden",
            ):
                VERIFIER.verify_artifact(copied)

    def test_artifact_root_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            linked = Path(temporary).resolve() / "artifact"
            linked.symlink_to(
                ROOT / "Vendor" / "NoopBandSDK",
                target_is_directory=True,
            )
            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "artifact root must not be a symlink",
            ):
                VERIFIER.verify_artifact(linked)

    def test_symlinked_vendor_ancestor_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary).resolve()
            vendor = temporary_root / "Vendor"
            vendor.mkdir()
            shutil.copytree(
                ROOT / "Vendor" / "NoopBandSDK",
                vendor / "NoopBandSDK",
            )
            candidate = temporary_root / "candidate"
            candidate.mkdir()
            (candidate / "Vendor").symlink_to(
                Path("..") / "Vendor",
                target_is_directory=True,
            )

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "artifact path ancestor must not be a symlink",
            ):
                VERIFIER.verify_artifact(candidate / "Vendor" / "NoopBandSDK")

    def test_symlinked_parent_ancestor_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            linked_parent = Path(temporary).resolve() / "candidate"
            linked_parent.symlink_to(ROOT, target_is_directory=True)

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "artifact path ancestor must not be a symlink",
            ):
                VERIFIER.verify_artifact(
                    linked_parent / "Vendor" / "NoopBandSDK"
                )


if __name__ == "__main__":
    unittest.main()
