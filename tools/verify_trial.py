#!/usr/bin/env python3
"""Verify a relocated bundle without normal app startup or installation effects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent.parent


def snapshot(app):
    return {str(p.relative_to(app)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in app.rglob('*') if p.is_file() and not p.is_symlink()}


def verify(source):
    with tempfile.TemporaryDirectory(prefix='trial-relocation-') as temporary:
        base=Path(temporary)/"移动 app's 文件夹";base.mkdir()
        app=base/source.name;shutil.copytree(source,app,symlinks=True)
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if any(k in info for k in ['ProjectRoot','PythonExecutable','CodexExecutable']):
            raise ValueError('Bundle still carries build-machine configuration')
        before=snapshot(app)
        binary=app/'Contents/MacOS/ContextCapture'
        result=subprocess.run([str(binary),'--diagnose-installation'],capture_output=True,text=True,check=True)
        diagnostic=json.loads(result.stdout)
        assert diagnostic['runtimeAvailable'] and diagnostic['portable']
        assert not diagnostic['hostRegistrationPerformed'] and not diagnostic['captureServicesStarted']
        if snapshot(app) != before:raise ValueError("Installation diagnostic modified app files")
        # Native checks are isolated in temporary directories and do not post submit events.
        native=subprocess.run([str(binary),'--self-test'],capture_output=True,text=True,check=True)
        print(native.stdout.strip().splitlines()[-1])
        python=app/'Contents/Frameworks/Python/bin/python3'
        testroot=base/'helper-checks';(testroot/'Tests').mkdir(parents=True)
        shutil.copytree(app/'Contents/Resources/Support/tools',testroot/'tools')
        for name in ['test_conversations.py','test_desktop_send_receipt.py','test_handoff_package.py','test_handoff_probe.py']:
            shutil.copy2(ROOT/'Tests'/name,testroot/'Tests'/name)
        subprocess.run([str(python),'-B','-E','-s','-m','unittest','discover','-s','Tests','-p','test_*.py'],cwd=testroot,check=True,capture_output=True,env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"})
        after=snapshot(app)
        changed=[p for p in before.keys()|after.keys() if before.get(p)!=after.get(p)]
        if changed:raise ValueError('Runtime modified sealed app files: '+repr(changed[:5]))
        result={'relocatedRuntime':True,'nativeChecks':True,'packagedHelperChecks':True,'sealedFilesUnchanged':True,
                'normalStartupUsed':False,'installedBrowserHost':False,'featureSetReduced':False}
        print(json.dumps(result,indent=2))
        return result

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('app',type=Path);args=parser.parse_args()
    verify(args.app.resolve())
