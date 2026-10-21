#!/usr/bin/env python3
"""Build using the persistent local development identity and install its Chrome bridge."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from local_signing import load_identity, sign

ROOT = Path(__file__).resolve().parent.parent
STAGE_ONLY = '--stage-only' in sys.argv
APP_NAME = 'Codex连续表达助手'
APP = ROOT / 'build' / ('staging' if STAGE_ONLY else '') / (APP_NAME + '.app')
SUPPORT = Path.home() / 'Library/Application Support/ContextCapturePrototype'

def run(*args):
    return subprocess.run(args, check=True, cwd=ROOT, capture_output=True).stdout

def main():
    identity = load_identity()  # Fail before touching installed files if identity is unavailable.
    subprocess.run(['swift', 'build', '-c', 'release', '-debug-info-format', 'none', '--product', 'ContextCapture'], cwd=ROOT, check=True)
    binary_dir = run('swift', 'build', '-c', 'release', '--show-bin-path').decode().strip()
    contents = APP / 'Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    (contents / 'Resources').mkdir(exist_ok=True)
    shutil.copy2(Path(binary_dir) / 'ContextCapture', contents / 'MacOS/ContextCapture')
    previous_versions = []
    for candidate in [ROOT/'build/连续表达原型.app/Contents/Info.plist',
                      ROOT/'build'/(APP_NAME+'.app')/'Contents/Info.plist',contents/'Info.plist']:
        if candidate.exists():
            try: previous_versions.append(int(plistlib.loads(candidate.read_bytes()).get('CFBundleVersion','1')))
            except (ValueError,TypeError): pass
    build_version = str(max(previous_versions,default=1)+1)
    info = {
        'CFBundleName': APP_NAME, 'CFBundleDisplayName': APP_NAME,
        'CFBundleIdentifier': 'local.contextcapture.prototype', 'CFBundleExecutable': 'ContextCapture',
        'CFBundleVersion': build_version, 'CFBundleShortVersionString': '0.1', 'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True,
        'NSMicrophoneUsageDescription': '仅在你点击开始表达后，采集你的语音并与所选素材关联。',
        'NSSpeechRecognitionUsageDescription': '将你本次表达转写为带时间的文字。',
        'NSAppleEventsUsageDescription': '读取你在 Finder 中选中的文件，保留文件来源。',
        'CodexExecutable': shutil.which('codex') or '', 'ProjectRoot': str(ROOT), 'PythonExecutable':sys.executable,
    }
    with (contents / 'Info.plist').open('wb') as f:
        plistlib.dump(info, f)
    sign(identity,APP)
    run('codesign','--verify','--strict',str(APP))

    # A public manifest key fixes the unpacked extension ID across rebuilds.
    key_path = ROOT / 'BrowserExtension/public-key.txt'
    if not key_path.exists():
        private = run('openssl', 'genrsa', '2048')
        public = subprocess.run(['openssl', 'rsa', '-pubout', '-outform', 'DER'], input=private, capture_output=True, check=True).stdout
        key_path.write_text(base64.b64encode(public).decode() + '\n')
    public_key = key_path.read_text().strip()
    digest = hashlib.sha256(base64.b64decode(public_key)).digest()[:16].hex()
    extension_id = ''.join(chr(ord('a') + int(c, 16)) for c in digest)
    manifest_path = ROOT / 'BrowserExtension/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['key'] = public_key
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

    if STAGE_ONLY:
        print('STAGED_APP:', APP)
        print('STAGED_EXTENSION:', ROOT / 'BrowserExtension')
        print('EXTENSION_ID:', extension_id)
        return

    SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copytree(ROOT / 'BrowserExtension', SUPPORT / 'BrowserExtension', dirs_exist_ok=True)
    host = SUPPORT / 'native-host'
    host.write_text('#!' + sys.executable + '\n' + (ROOT / 'tools/native_host.py').read_text())
    host.chmod(0o700)
    host_manifest = {
        'name': 'local.contextcapture.bridge', 'description': 'Local prototype selection bridge',
        'path': str(host), 'type': 'stdio', 'allowed_origins': ['chrome-extension://' + extension_id + '/'],
    }
    target = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'
    target.mkdir(parents=True, exist_ok=True)
    (target / 'local.contextcapture.bridge.json').write_text(json.dumps(host_manifest, indent=2) + '\n')
    print('APP:', APP)
    print('EXTENSION:', SUPPORT / 'BrowserExtension')
    print('EXTENSION_ID:', extension_id)

if __name__ == '__main__':
    main()
