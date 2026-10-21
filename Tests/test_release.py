import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import release

class ReleaseChecks(unittest.TestCase):
    def test_tampered_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'archive';path.write_bytes(b'wrong')
            with self.assertRaises(ValueError):release.verify_digest(path,'0'*64)
            release.verify_digest(path,hashlib.sha256(b'wrong').hexdigest())
    def archive(self,path,name,link=None):
        with tarfile.open(path,'w:gz') as t:
            info=tarfile.TarInfo(name)
            if link is not None:info.type=tarfile.SYMTYPE;info.linkname=link
            else:info.size=2
            t.addfile(info,None if link is not None else io.BytesIO(b'ok'))
    def test_archive_cannot_escape_or_link_outside(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);archive=p/'runtime.tar.gz'
            for name,link in [('../escape',None),('/escape',None),('python/bin/evil','../../../escape')]:
                self.archive(archive,name,link)
                with self.assertRaises(ValueError):release.extract_runtime(archive,p/'extract')
    def test_internal_python_symlink_is_supported(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);archive=p/'runtime.tar.gz';self.archive(archive,'python/bin/python3','python3.13')
            release.extract_runtime(archive,p/'extract')
            self.assertTrue((p/'extract/python/bin/python3').is_symlink())
    def test_portable_bundle_includes_all_helpers_without_machine_paths(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);runtime=p/'runtime';(runtime/'bin').mkdir(parents=True)
            (runtime/'bin/python3').write_text('fake runtime')
            binary=p/'binary';binary.write_bytes(b'fixture')
            app=release.assemble_app(p/'output',binary,runtime,'0.2.0-trial.1','1')
            info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
            for key in ['ProjectRoot','PythonExecutable','CodexExecutable']:self.assertNotIn(key,info)
            self.assertTrue(info['PortableDistribution'])
            self.assertTrue((app/'Contents/Resources/Python/bin/python3').is_file())
            self.assertFalse((app/'Contents/Frameworks/Python').exists())
            self.assertEqual(info['CFBundleShortVersionString'],'0.2.0')
            self.assertEqual(info['TrialVersionLabel'],'0.2.0-trial.1')
            self.assertEqual(info['CFBundleIdentifier'],'local.contextcapture.prototype')
            for helper in release.HELPERS:self.assertTrue((app/'Contents/Resources/Support/tools'/helper).is_file(),helper)
            self.assertTrue((app/'Contents/Resources/Support/BrowserExtension/manifest.json').exists())
            self.assertTrue((app/'Contents/Resources/Support/Fixtures/Finder/示例A.txt').exists())
            for name in ['LICENSE.openssl-3.txt','LICENSE.tcl.txt','LICENSE.libffi.txt','LICENSE.zlib.txt']:
                self.assertTrue((app/'Contents/Resources/Licenses/StandalonePython'/name).is_file(),name)
            self.assertFalse(any(x.name in ['identity.json','auth.json'] for x in app.rglob('*')))
    def test_missing_or_modified_native_dependency_notice_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'LICENSE.openssl-3.txt').write_text('original')
            inventory={'files':{'LICENSE.openssl-3.txt':hashlib.sha256(b'original').hexdigest(),'LICENSE.tcl.txt':'0'*64}}
            with self.assertRaises(ValueError):release.verify_licenses(p,inventory)
            del inventory['files']['LICENSE.tcl.txt']
            release.verify_licenses(p,inventory)
            (p/'LICENSE.openssl-3.txt').write_text('modified')
            with self.assertRaises(ValueError):release.verify_licenses(p,inventory)
    def test_unsigned_artifact_never_qualifies_as_ready(self):
        self.assertFalse(release.publish_ready({'notarized':False,'cleanMacAccepted':True,'signed':True}))
        self.assertFalse(release.publish_ready({'notarized':True,'cleanMacAccepted':False,'signed':True}))
        self.assertFalse(release.publish_ready({'notarized':True,'cleanMacAccepted':True,'signed':False}))
        self.assertTrue(release.publish_ready({'notarized':True,'cleanMacAccepted':True,'signed':True}))
    def test_clean_mac_evidence_requires_all_features_and_matching_artifact(self):
        status={'version':'0.2.0-trial.1','signed':True,'notarized':True}
        report={'version':status['version'],'appBundleSHA256':'a'*64,'checks':{key:True for key in release.ACCEPTANCE_CHECKS}}
        good=release.accept_clean_mac(status,report,'a'*64)
        self.assertTrue(good['cleanMacAccepted'])
        report['checks']['image']=False
        with self.assertRaises(ValueError):release.accept_clean_mac(status,report,'a'*64)
        report['checks']['image']=True
        with self.assertRaises(ValueError):release.accept_clean_mac(status,report,'b'*64)
        with self.assertRaises(ValueError):release.accept_clean_mac({**status,'notarized':False},report,'a'*64)
    def test_bundle_digest_includes_helper_and_symlink_changes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'main').write_text('same binary');(p/'helper.py').write_text('one')
            (p/'alias').symlink_to('main');first=release.bundle_digest(p)
            (p/'helper.py').write_text('two');second=release.bundle_digest(p)
            self.assertNotEqual(first,second)
            (p/'alias').unlink();(p/'alias').symlink_to('helper.py')
            self.assertNotEqual(second,release.bundle_digest(p))
    def test_unnotarized_trial_requires_seal_and_verified_exact_bundle(self):
        status={'signed':False,'notarized':False,'cleanMacAccepted':False,'signatureKind':'ad-hoc','sealedBundleSHA256':'a'*64}
        with self.assertRaises(ValueError):release.approve_unnotarized_trial(status,'a'*64,verified=False)
        with self.assertRaises(ValueError):release.approve_unnotarized_trial(status,'b'*64,verified=True)
        with self.assertRaises(ValueError):release.approve_unnotarized_trial({**status,'signatureKind':'none'},'a'*64,verified=True)
        approved=release.approve_unnotarized_trial(status,'a'*64,verified=True)
        self.assertTrue(approved['unnotarizedTrialReady'])
        self.assertFalse(release.publish_ready(approved))
        self.assertFalse(approved['notarized']);self.assertFalse(approved['cleanMacAccepted'])
    def test_ad_hoc_seal_does_not_access_developer_certificate(self):
        arguments=release.adhoc_arguments(Path('/test/example.app'))
        self.assertEqual(arguments[arguments.index('--sign')+1],'-')
        self.assertIn('--timestamp=none',arguments)
        self.assertNotIn('--keychain',arguments)
        self.assertNotIn('--options',arguments)
    def test_distribution_signer_requires_developer_id(self):
        for value in ['-','ContextCapture Local Development','Apple Development: Example']:
            with self.assertRaises(ValueError):release.validate_identity_name(value)
        release.validate_identity_name('Developer ID Application: Example (TEST123456)')

if __name__=='__main__':unittest.main()
