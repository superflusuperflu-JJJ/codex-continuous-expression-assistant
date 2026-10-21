#!/usr/bin/env python3
"""Portable distribution only. Never installs/registers/runs the normal app or uses local signing keys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parent.parent
APP_NAME='Codex连续表达助手'
LICENSE_ROOT=ROOT/'Resources/PythonLicenses'
REQUIRED_NOTICES={'LICENSE.cpython.txt','LICENSE.openssl-3.txt','LICENSE.libffi.txt','LICENSE.sqlite.txt','LICENSE.tcl.txt','LICENSE.zlib.txt','LICENSE.liblzma.txt','LICENSE.bzip2.txt','LICENSE.expat.txt','LICENSE.mpdecimal.txt','LICENSE.ncurses.txt','LICENSE.libedit.txt','LICENSE.zstd.txt'}
HELPERS=('native_host.py','handoff_package.py','codex_handoff_probe.py','codex_conversations.py',
         'prepare_desktop_draft.py','desktop_send_receipt.py','installation_probe.py')
ENTITLEMENTS={'com.apple.security.device.audio-input':True,'com.apple.security.automation.apple-events':True}
ACCEPTANCE_CHECKS=('installation','voice','browserText','link','image','finderFiles','association','promptEditing','choices','targetSelection','submission','receipt','existingDraftProtection','drawer','reopen','export')


def run(*args,**kwargs):
    return subprocess.run(args,check=True,text=True,**kwargs)


def verify_digest(path,expected):
    digest=hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if digest!=expected:raise ValueError('Runtime archive checksum mismatch; stopped before assembly')


def extract_runtime(archive,destination):
    destination=Path(destination).resolve()
    with tarfile.open(archive,'r:gz') as stream:
        members=stream.getmembers()
        if len(members)>20000 or sum(x.size for x in members)>1024**3:
            raise ValueError('Unexpected runtime archive size')
        for member in members:
            if Path(member.name).is_absolute() or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError('Unsupported runtime archive entry')
            target=(destination/member.name).resolve()
            if not target.is_relative_to(destination):raise ValueError('Archive path escapes destination')
            if member.issym() or member.islnk():
                link=((target.parent if member.issym() else destination)/member.linkname).resolve()
                if not link.is_relative_to(destination):raise ValueError('Archive link escapes destination')
        destination.mkdir(parents=True,exist_ok=True)
        stream.extractall(destination,filter='data')


def verify_licenses(folder,inventory):
    files=inventory.get('files',{})
    if not files:raise ValueError('Missing runtime license inventory')
    for name,digest in files.items():
        if Path(name).name!=name or not (Path(folder)/name).is_file():
            raise ValueError('Missing native runtime dependency notice: '+name)
        verify_digest(Path(folder)/name,digest)


def assemble_app(output,binary,runtime,version,build):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-trial\.\d+)?',version) or not re.fullmatch(r'[1-9]\d*',str(build)):
        raise ValueError('Invalid release version/build')
    license_inventory=json.loads((LICENSE_ROOT/'inventory.json').read_text())
    if not REQUIRED_NOTICES.issubset(license_inventory.get('files',{})):
        raise ValueError('Incomplete native runtime dependency license inventory')
    verify_licenses(LICENSE_ROOT,license_inventory)
    app=Path(output)/(APP_NAME+'.app')
    if app.exists():raise FileExistsError('Refusing to mix an existing bundle; use a fresh output directory')
    contents=app/'Contents';(contents/'MacOS').mkdir(parents=True)
    support=contents/'Resources/Support';(support/'tools').mkdir(parents=True)
    shutil.copy2(binary,contents/'MacOS/ContextCapture');(contents/'MacOS/ContextCapture').chmod(0o755)
    shutil.copytree(runtime,contents/'Resources/Python',symlinks=True)
    for name in HELPERS:shutil.copy2(ROOT/'tools'/name,support/'tools'/name)
    for name in ['BrowserExtension','Fixtures']:
        shutil.copytree(ROOT/name,support/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc','.DS_Store'))
    info={'CFBundleName':APP_NAME,'CFBundleDisplayName':APP_NAME,'CFBundleIdentifier':'local.contextcapture.prototype',
          'CFBundleExecutable':'ContextCapture','CFBundleVersion':str(build),'CFBundleShortVersionString':version.split('-')[0],'TrialVersionLabel':version,
          'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,
          'PortableDistribution':True,'NSMicrophoneUsageDescription':'仅在你点击开始表达后，采集你的语音并与所选素材关联。',
          'NSSpeechRecognitionUsageDescription':'将你本次表达转写为带时间的文字。',
          'NSAppleEventsUsageDescription':'读取你在 Finder 中选中的文件，保留文件来源。'}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    licenses=contents/'Resources/Licenses';licenses.mkdir()
    shutil.copytree(LICENSE_ROOT,licenses/'StandalonePython')
    # Standalone Python retains its full standard library, binary dependency licenses and notices.
    for path in (contents/'Resources/Python').rglob('*'):
        if path.is_file() and not path.is_symlink() and (path.name.startswith('LICENSE') or path.name.startswith('COPYING')):
            target=licenses/('python-'+str(path.relative_to(contents/'Resources/Python')).replace('/','-'))
            shutil.copy2(path,target)
    (licenses/'RUNTIME-SOURCE.txt').write_text('CPython via Astral python-build-standalone.\nhttps://github.com/astral-sh/python-build-standalone\nPinned download and SHA256: tools/python-runtime.json in the source repository.\n')
    return app


def publish_ready(status):
    return all(status.get(k) is True for k in ['signed','notarized','cleanMacAccepted'])


def bundle_digest(app):
    rows=[]
    for path in sorted(Path(app).rglob('*')):
        relative=path.relative_to(app).as_posix()
        if path.is_symlink():rows.append([relative,'symlink',os.readlink(path)])
        elif path.is_file():rows.append([relative,'file',path.stat().st_mode & 0o777,hashlib.sha256(path.read_bytes()).hexdigest()])
        elif path.is_dir():rows.append([relative,'directory',path.stat().st_mode & 0o777])
    return hashlib.sha256(json.dumps(rows,ensure_ascii=True,separators=(',',':')).encode()).hexdigest()


def accept_clean_mac(status,report,bundle_sha):
    checks=report.get('checks',{})
    if (not status.get('signed') or not status.get('notarized') or report.get('version')!=status.get('version')
        or report.get('appBundleSHA256')!=bundle_sha or not all(checks.get(k) is True for k in ACCEPTANCE_CHECKS)):
        raise ValueError('Clean-Mac acceptance requires the signed/notarized candidate, matching hash/version and all feature checks')
    return {**status,'cleanMacAccepted':True,'state':'ready-for-small-group-trial','acceptedBundleSHA256':bundle_sha,'acceptance':report}


def validate_identity_name(identity):
    if not identity.startswith('Developer ID Application: ') or '\n' in identity:
        raise ValueError('Distribution requires an explicit Developer ID Application identity; no local/ad-hoc fallback')


def macho_paths(app):
    magic={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf'}
    paths=[]
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:head=stream.read(4)
            if head in magic:paths.append(path)
    return sorted(paths,key=lambda p:len(p.parts),reverse=True)


def adhoc_arguments(path):
    return ['codesign','--force','--sign','-','--timestamp=none',str(path)]


def seal_unnotarized(app):
    for path in macho_paths(app):run(*adhoc_arguments(path))
    run(*adhoc_arguments(app))
    run('codesign','--verify','--deep','--strict',str(app))


def approve_unnotarized_trial(status,bundle_sha,verified):
    if (status.get('notarized') or status.get('signatureKind')!='ad-hoc' or
        status.get('sealedBundleSHA256')!=bundle_sha or not verified):
        raise ValueError('Unnotarized trial requires an exact sealed and locally verified bundle')
    return {**status,'state':'unnotarized-public-prerelease','unnotarizedTrialReady':True,
            'localPortableVerified':True,'trialBundleSHA256':bundle_sha}


def sign_distribution(app,identity,entitlements):
    validate_identity_name(identity)
    for path in macho_paths(app):
        run('codesign','--force','--sign',identity,'--options','runtime','--timestamp',str(path))
    run('codesign','--force','--sign',identity,'--options','runtime','--timestamp','--entitlements',str(entitlements),str(app))
    run('codesign','--verify','--deep','--strict',str(app))


def prepare(output,cache,version,build):
    output=Path(output).resolve();cache=Path(cache).resolve();output.mkdir(parents=True,exist_ok=True);cache.mkdir(parents=True,exist_ok=True)
    pinned=json.loads((ROOT/'tools/python-runtime.json').read_text())
    archive=cache/'python-runtime.tar.gz'
    if not archive.exists():
        temporary=archive.with_suffix('.download')
        run('curl','--fail','--location','--retry','2','--output',str(temporary),pinned['url'])
        verify_digest(temporary,pinned['sha256']);temporary.replace(archive)
    verify_digest(archive,pinned['sha256'])
    run('swift','build','-c','release','-debug-info-format','none','--product','ContextCapture',
        '-Xswiftc','-debug-prefix-map','-Xswiftc',str(ROOT)+'=.',cwd=ROOT)
    binary_dir=subprocess.check_output(['swift','build','-c','release','--show-bin-path'],cwd=ROOT,text=True).strip()
    with tempfile.TemporaryDirectory(prefix='portable-runtime-') as folder:
        extract_runtime(archive,Path(folder))
        app=assemble_app(output,Path(binary_dir)/'ContextCapture',Path(folder)/'python',version,build)
    entitlements=output/'release-entitlements.plist';entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
    status={'version':version,'build':str(build),'signed':False,'notarized':False,'cleanMacAccepted':False,
            'state':'unsigned-staging-only','runtimeSHA256':pinned['sha256'],'featuresReduced':False}
    write_status(output,status)
    print('Prepared portable app (unsigned staging; not for normal download installation):',app)
    return app


def write_status(output,status):
    status['publishReady']=publish_ready(status)
    (output/'release-status.json').write_text(json.dumps(status,ensure_ascii=False,indent=2)+'\n')


def package(output,allow_unnotarized=False):
    status=json.loads((output/'release-status.json').read_text());app=output/(APP_NAME+'.app')
    if not app.is_dir():raise ValueError('Prepare the complete app first')
    if allow_unnotarized:
        run('codesign','--verify','--deep','--strict',str(app))
        from verify_trial import verify
        verification=verify(app)
        status=approve_unnotarized_trial(status,bundle_digest(app),verified=all(verification.get(k) is True for k in ['relocatedRuntime','nativeChecks','packagedHelperChecks','sealedFilesUnchanged']))
        write_status(output,status)
    if status.get('signed'):run('codesign','--verify','--deep','--strict',str(app))
    if status.get('notarized'):run('xcrun','stapler','validate',str(app))
    if status.get('cleanMacAccepted') and status.get('acceptedBundleSHA256')!=bundle_digest(app):
        raise ValueError('Candidate changed after acceptance; repeat clean-Mac verification')
    stage=output/'dmg-content'
    if stage.exists():shutil.rmtree(stage)
    stage.mkdir();shutil.copytree(app,stage/app.name,symlinks=True)
    (stage/'Applications').symlink_to('/Applications')
    shutil.copy2(ROOT/'docs/trial-installation.md',stage/'安装与试用说明.txt')
    if allow_unnotarized:
        (stage/'未经过Apple公证的测试版.txt').write_text('本测试版未经过 Apple 公证，不是 App Store 或 Apple 认证的软件。\n仅完成本机自动检查与搬迁运行，另一台 Mac 的完整安装与功能验收尚未完成。\n功能保持完整；请阅读安装说明，自行决定是否在系统设置中允许打开。\n')
    elif not publish_ready(status):
        (stage/'尚未通过正式分发验证.txt').write_text('这是完整功能的暂存构建，尚未满足正式分发条件。\n需要 Developer ID 签名、Apple 公证及另一台 Mac 的完整验收。\n不要通过关闭 Gatekeeper 或删除隔离属性来作为正常安装流程。\n')
    suffix='-UNNOTARIZED-TEST' if allow_unnotarized else ('' if publish_ready(status) else '-STAGING-NOT-FOR-DISTRIBUTION')
    dmg=output/(APP_NAME+'-'+status['version']+'-arm64'+suffix+'.dmg')
    run('hdiutil','create','-volname',APP_NAME,'-srcfolder',str(stage),'-ov','-format','UDZO',str(dmg))
    (output/(dmg.name+'.sha256')).write_text(hashlib.sha256(dmg.read_bytes()).hexdigest()+'  '+dmg.name+'\n')
    return dmg


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['prepare','sign','seal-unnotarized','notarize','accept-clean-mac','package','status'])
    parser.add_argument('--output',type=Path,default=ROOT/'build/release')
    parser.add_argument('--cache',type=Path,default=ROOT/'build/runtime-cache')
    parser.add_argument('--version',default='0.2.0-trial.1');parser.add_argument('--build',default='1')
    parser.add_argument('--identity');parser.add_argument('--keychain-profile')
    parser.add_argument('--acceptance-report',type=Path)
    parser.add_argument('--unnotarized-trial',action='store_true',help='Explicitly package a locally verified, unnotarized public prerelease; never marks notarization/clean-Mac acceptance')
    args=parser.parse_args();out=args.output.resolve();app=out/(APP_NAME+'.app')
    if args.command=='prepare':prepare(out,args.cache,args.version,args.build);return
    status=json.loads((out/'release-status.json').read_text())
    if args.command=='seal-unnotarized':
        seal_unnotarized(app)
        status.update(signed=False,notarized=False,cleanMacAccepted=False,signatureKind='ad-hoc',unnotarizedTrialReady=False,
                      sealedBundleSHA256=bundle_digest(app),state='ad-hoc-sealed-awaiting-local-verification')
        write_status(out,status)
    elif args.command=='sign':
        if not args.identity:parser.error('--identity is required; Developer ID Application only')
        sign_distribution(app,args.identity,out/'release-entitlements.plist')
        status.update(signed=True,notarized=False,cleanMacAccepted=False,signatureKind='developer-id',unnotarizedTrialReady=False,state='signed-awaiting-notarization');write_status(out,status)
    elif args.command=='notarize':
        if not status.get('signed') or not args.keychain_profile:parser.error('Developer ID signature and existing --keychain-profile required')
        submission=out/'notary-submission.zip'
        run('ditto','-c','-k','--keepParent',str(app),str(submission))
        run('xcrun','notarytool','submit',str(submission),'--keychain-profile',args.keychain_profile,'--wait')
        run('xcrun','stapler','staple',str(app));run('xcrun','stapler','validate',str(app))
        run('spctl','--assess','--type','execute','--verbose=2',str(app))
        status.update(notarized=True,state='notarized-awaiting-clean-Mac-test');write_status(out,status)
    elif args.command=='accept-clean-mac':
        if not args.acceptance_report:parser.error('--acceptance-report is required after real second-Mac testing')
        report=json.loads(args.acceptance_report.read_text())
        run('codesign','--verify','--deep','--strict',str(app))
        run('xcrun','stapler','validate',str(app))
        sha=bundle_digest(app)
        write_status(out,accept_clean_mac(status,report,sha))
    elif args.command=='package':print(package(out,allow_unnotarized=args.unnotarized_trial))
    else:print(json.dumps({**status,'currentBundleSHA256':bundle_digest(app)},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
