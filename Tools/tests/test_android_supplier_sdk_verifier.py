from __future__ import annotations

import hashlib
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Tools" / "local" / "verify-android-supplier-sdk.py"
SPEC = importlib.util.spec_from_file_location("android_supplier_sdk_verifier", MODULE_PATH)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)


class AndroidSupplierSdkVerifierTest(unittest.TestCase):
    def _git(self, repository: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _repository(self, temporary: Path) -> Path:
        repository = temporary / "repository"
        wrapper = repository / "android" / "gradle" / "wrapper" / "gradle-wrapper.jar"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_bytes(b"synthetic wrapper")
        self._git(repository, "init", "-q")
        self._git(repository, "add", wrapper.relative_to(repository).as_posix())
        return repository

    def _aar(
        self,
        path: Path,
        *,
        classes: tuple[str, ...] = ("com.example.Required",),
        native_entries: tuple[str, ...] = (),
    ) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        classes_jar = path.parent / "classes.jar"
        with ZipFile(classes_jar, "w") as archive:
            for class_name in classes:
                archive.writestr(class_name.replace(".", "/") + ".class", b"class")
        with ZipFile(path, "w") as archive:
            archive.write(classes_jar, "classes.jar")
            archive.writestr("AndroidManifest.xml", b"manifest")
            for entry in native_entries:
                archive.writestr(entry, b"native")
        classes_jar.unlink()
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _config(
        self,
        repository: Path,
        sdk_root: Path,
        artifact: Path,
        digest: str,
        *,
        native_abis: str = "",
        native_libraries: str = "",
    ) -> Path:
        config = repository / "android" / "noop-supplier-sdk.properties"
        config.write_text(
            "\n".join(
                [
                    "enabled=true",
                    f"sdk.root={sdk_root}",
                    "artifact.count=1",
                    f"artifact.0.path={artifact.relative_to(sdk_root).as_posix()}",
                    f"artifact.0.sha256={digest}",
                    "artifact.0.requiredClasses=com.example.Required",
                    f"artifact.0.nativeAbis={native_abis}",
                    f"artifact.0.nativeLibraries={native_libraries}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        return config

    def test_exact_aar_and_class_inventory_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            sdk_root = root / "supplier"
            artifact = sdk_root / "core" / "transport.aar"
            digest = self._aar(artifact)
            config = self._config(repository, sdk_root, artifact, digest)

            result = VERIFIER.verify(config, repository)

            self.assertTrue(result["enabled"])
            self.assertEqual(1, len(result["artifacts"]))
            self.assertEqual(digest, result["artifacts"][0]["sha256"])

    def test_disabled_config_is_default_off(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            config = repository / "android" / "noop-supplier-sdk.properties"
            config.write_text("enabled=false\n", encoding="utf-8")

            result = VERIFIER.verify(config, repository)

            self.assertEqual({"enabled": False, "artifacts": []}, result)

    def test_duplicate_config_key_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            config = repository / "android" / "noop-supplier-sdk.properties"
            config.write_text("enabled=true\nenabled=false\n", encoding="utf-8")

            with self.assertRaisesRegex(VERIFIER.VerificationError, "duplicates enabled"):
                VERIFIER.verify(config, repository)

    def test_existing_non_file_config_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            config = repository / "android" / "noop-supplier-sdk.properties"
            config.mkdir()

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "config must be a regular file",
            ):
                VERIFIER.verify(config, repository)

    def test_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            sdk_root = root / "supplier"
            artifact = sdk_root / "core" / "transport.aar"
            self._aar(artifact)
            config = self._config(repository, sdk_root, artifact, "0" * 64)

            with self.assertRaisesRegex(VERIFIER.VerificationError, "digest mismatch"):
                VERIFIER.verify(config, repository)

    def test_missing_required_class_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            sdk_root = root / "supplier"
            artifact = sdk_root / "core" / "transport.aar"
            digest = self._aar(artifact, classes=("com.example.Other",))
            config = self._config(repository, sdk_root, artifact, digest)

            with self.assertRaisesRegex(VERIFIER.VerificationError, "missing required class"):
                VERIFIER.verify(config, repository)

    def test_unconfigured_native_binary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            sdk_root = root / "supplier"
            artifact = sdk_root / "core" / "transport.aar"
            digest = self._aar(
                artifact,
                native_entries=("jni/arm64-v8a/libunexpected.so",),
            )
            config = self._config(repository, sdk_root, artifact, digest)

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "native binary inventory",
            ):
                VERIFIER.verify(config, repository)

    def test_exact_native_abi_inventory_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            sdk_root = root / "supplier"
            artifact = sdk_root / "core" / "transport.aar"
            digest = self._aar(
                artifact,
                native_entries=(
                    "jni/arm64-v8a/libtransport.so",
                    "jni/x86_64/libtransport.so",
                ),
            )
            config = self._config(
                repository,
                sdk_root,
                artifact,
                digest,
                native_abis="arm64-v8a,x86_64",
                native_libraries="libtransport.so",
            )

            result = VERIFIER.verify(config, repository)

            self.assertEqual(
                ["arm64-v8a", "x86_64"],
                result["artifacts"][0]["nativeAbis"],
            )

    def test_tracked_supplier_binary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            binary = repository / "android" / "local-supplier-sdk" / "vendor.aar"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"binary")
            self._git(repository, "add", "-f", binary.relative_to(repository).as_posix())

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "local supplier staging files must not be tracked",
            ):
                VERIFIER.verify_repository_boundary(repository)

    def test_tracked_local_config_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = self._repository(root)
            config = repository / "android" / "noop-supplier-sdk.properties"
            config.write_text("enabled=false\n", encoding="utf-8")
            self._git(repository, "add", config.relative_to(repository).as_posix())

            with self.assertRaisesRegex(
                VERIFIER.VerificationError,
                "local supplier config must not be tracked",
            ):
                VERIFIER.verify_repository_boundary(repository)


class AndroidSupplierGradleContractTest(unittest.TestCase):
    def test_default_build_has_no_supplier_artifact_pin(self) -> None:
        source = (ROOT / "android" / "app" / "build.gradle.kts").read_text(
            encoding="utf-8"
        )
        self.assertIn('rootProject.file("noop-supplier-sdk.properties")', source)
        self.assertIn("val supplierSdkEnabled", source)
        self.assertIn('add("fullImplementation", files(supplierArtifactFiles))', source)
        self.assertIn('maybeCreate("full").java.srcDir("src/veepoo/java")', source)
        self.assertIn('"VEEPOO_ADAPTER_AVAILABLE", "false"', source)
        self.assertIn('name.contains("Full")', source)
        self.assertIn("packagesSupplierRelease", source)
        self.assertNotRegex(source, r"jar_core/[A-Za-z0-9_.+-]+\.aar")
        self.assertNotRegex(source, r"\b[0-9a-f]{64}\b")

    def test_local_config_and_vendor_binaries_are_ignored(self) -> None:
        source = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("android/noop-supplier-sdk.properties", source)
        self.assertIn("android/local-supplier-sdk/", source)
        self.assertIn("*.aar", source)
        self.assertIn("*.so", source)
        self.assertIn("*.jar", source)
        self.assertIn("!android/gradle/wrapper/gradle-wrapper.jar", source)


if __name__ == "__main__":
    unittest.main()
