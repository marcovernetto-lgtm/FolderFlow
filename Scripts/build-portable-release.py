#!/usr/bin/env python3
"""Build a universal macOS app using the encrypted login Keychain, without a provisioning profile."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--test-only', action='store_true')
options = parser.parse_args()

def run(*args):
    subprocess.run(args, cwd=root, check=True)

# Pinned SDKs use the data-protection Keychain by default, which requires a provisioned identity.
# The portable macOS build uses the OS login Keychain, retaining per-app access controls.
patches = {
    '.build/checkouts/firebase-ios-sdk/FirebaseAuth/Sources/Swift/Storage/AuthKeychainStorageReal.swift': [
        ('  private init() {}', '''  private init() {}

  private func loginKeychain(_ attributes: [String: Any]) -> [String: Any] {
    var result = attributes
    #if os(macOS)
    result.removeValue(forKey: kSecAttrAccessible as String)
    result[kSecUseDataProtectionKeychain as String] = false
    #endif
    return result
  }'''),
        ('query as CFDictionary', 'loginKeychain(query) as CFDictionary'),
        ('attributes as CFDictionary', 'loginKeychain(attributes) as CFDictionary'),
    ],
    '.build/checkouts/GoogleSignIn-iOS/GoogleSignIn/Sources/GIDSignIn.m': [
        ('[[GTMKeychainStore alloc] initWithItemName:kGTMAppAuthKeychainName];',
         '[[GTMKeychainStore alloc] initWithItemName:kGTMAppAuthKeychainName keychainAttributes:[NSSet setWithObject:GTMKeychainAttribute.useFileBasedKeychain]];'),
    ],
}
backups = {}
try:
    for relative, replacements in patches.items():
        path = root / relative
        original = path.read_text()
        backups[path] = (original, path.stat().st_mode)
        path.chmod(0o644)
        updated = original
        for old, new in replacements:
            if old not in updated:
                raise RuntimeError('SDK source changed; review portable Keychain patch: ' + relative)
            updated = updated.replace(old, new)
        path.write_text(updated)
    run('swift', 'build', '--disable-sandbox', '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64')
    if options.test_only:
        raise SystemExit(0)
    products = Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64', '--show-bin-path'], cwd=root, text=True).strip())
    app = root / 'dist/portable/FolderFlow.app'
    if app.exists():
        raise FileExistsError(app)
    (app / 'Contents/MacOS').mkdir(parents=True)
    resources = app / 'Contents/Resources'
    resources.mkdir()
    shutil.copy2(products / 'FolderFlow', app / 'Contents/MacOS/FolderFlow')
    run('strip', '-S', str(app / 'Contents/MacOS/FolderFlow'))
    for bundle in products.glob('*.bundle'):
        shutil.copytree(bundle, resources / bundle.name)
    frameworks = products / 'PackageFrameworks'
    if frameworks.exists():
        shutil.copytree(frameworks, app / 'Contents/Frameworks')
    for name in ['FolderFlow.icns', 'app_icon.png', 'GoogleService-Info.plist']:
        shutil.copy2(root / 'Sources/FolderFlow/Resources' / name, resources / name)
    info = plistlib.loads((root / 'Configuration/Info.plist').read_bytes())
    info.update(CFBundleExecutable='FolderFlow', CFBundleIdentifier='com.unshapedstudio.folderflow')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Sign the fresh bundle locally; no personal certificates or provisioning profiles are included.
    for framework in (app / 'Contents/Frameworks').glob('*.framework'):
        run('codesign', '--force', '--sign', '-', str(framework))
    run('codesign', '--force', '--sign', '-', str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    print('Built:', app)
finally:
    for path, (original, mode) in backups.items():
        path.write_text(original)
        path.chmod(mode)
