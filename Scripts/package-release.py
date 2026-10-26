#!/usr/bin/env python3
"""Package an existing signed FolderFlow app without changing its signature."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def package(app, output):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.unshapedstudio.folderflow":
        raise ValueError("Choose the current signed FolderFlow application.")
    version = info["CFBundleShortVersionString"]
    if not version or any(c not in "0123456789.-" for c in version):
        raise ValueError("Invalid application version.")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    architectures = subprocess.check_output(
        ["lipo", "-archs", str(app / "Contents/MacOS/FolderFlow")], text=True
    ).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("The release must contain both Apple Silicon and Intel code.")

    profile = app / "Contents/embedded.provisionprofile"
    signing = {"developmentProfile": profile.exists(), "notarized": False}
    if profile.exists():
        values = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile)]))
        expiration = values.get("ExpirationDate")
        signing["profileExpiresAt"] = expiration.isoformat() + "Z" if expiration else None
        signing["registeredDeviceCount"] = len(values.get("ProvisionedDevices", []))
    signing["notarized"] = subprocess.run(
        ["xcrun", "stapler", "validate", str(app)], capture_output=True
    ).returncode == 0
    details = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True).stderr
    signing["developerID"] = "Authority=Developer ID Application:" in details
    signing["publicDistributionReady"] = signing["developerID"] and signing["notarized"] and not profile.exists()

    output.mkdir(parents=True, exist_ok=True)
    stem = f"FolderFlow-{version}-universal"
    dmg, archive = output / (stem + ".dmg"), output / (stem + ".zip")
    sums = output / f"SHA256SUMS-{version}.txt"
    manifest = output / f"release-info-{version}.json"
    if any(p.exists() for p in [dmg, archive, sums, manifest]):
        raise FileExistsError("Release files already exist. Choose a new output directory.")

    notice = (
        "FolderFlow — anteprima di sviluppo\n\n"
        "Questa build non è notarizzata per la distribuzione pubblica.\n"
        "La firma di sviluppo può limitare i Mac autorizzati e ha una scadenza.\n"
        "Sugli altri Mac compilare i sorgenti in Xcode con il proprio team Apple.\n"
        "Non sono inclusi cataloghi personali, sessioni di accesso o credenziali amministrative.\n\n"
        "Sorgenti e istruzioni: https://github.com/marcovernetto-lgtm/FolderFlow\n"
    )
    if signing.get("profileExpiresAt"):
        notice += "Scadenza profilo di questa build (UTC): " + signing["profileExpiresAt"] + "\n"
    with tempfile.TemporaryDirectory(prefix="folderflow-package-") as folder:
        stage = Path(folder) / stem
        stage.mkdir()
        staged_app = stage / "FolderFlow.app"
        run("ditto", str(app), str(staged_app))
        run("codesign", "--verify", "--deep", "--strict", str(staged_app))
        (stage / "Applications").symlink_to("/Applications")
        (stage / "LEGGIMI.txt").write_text(notice, encoding="utf-8")
        run("hdiutil", "create", "-volname", "FolderFlow", "-srcfolder", str(stage), "-format", "UDZO", str(dmg))
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(archive))
    run("hdiutil", "verify", str(dmg))
    run("unzip", "-tq", str(archive))
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [dmg, archive]}
    sums.write_text("".join(f"{digest}  {name}\n" for name, digest in hashes.items()), encoding="utf-8")
    manifest.write_text(json.dumps({
        "version": version, "build": info["CFBundleVersion"],
        "architectures": architectures, "signing": signing, "sha256": hashes,
    }, indent=2) + "\n", encoding="utf-8")
    print("Packages verified. Public distribution ready:", signing["publicDistributionReady"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    options = parser.parse_args()
    package(options.app.resolve(), options.output_dir.resolve())
