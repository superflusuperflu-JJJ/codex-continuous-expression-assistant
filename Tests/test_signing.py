import json
from pathlib import Path
import tempfile
import unittest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from local_signing import load_identity, signing_arguments

class SigningChecks(unittest.TestCase):
    def test_missing_config_never_silently_falls_back_to_adhoc(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):load_identity(Path(d))
    def test_certificate_pinned_requirement_does_not_pin_binary_hash(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d);(folder/'identity.keychain-db').touch()
            fingerprint='A'*40
            (folder/'identity.json').write_text(json.dumps({'sha1':fingerprint,'keychain':'identity.keychain-db'}))
            identity=load_identity(folder);args=signing_arguments(identity,Path('/tmp/app.app'))
            self.assertIn(fingerprint,args)
            requirement=next(x for x in args if x.startswith('=designated =>'))
            self.assertIn('certificate leaf = H"'+fingerprint+'"',requirement)
            self.assertNotIn('cdhash',requirement)
            self.assertIn('local.contextcapture.prototype',requirement)
    def test_invalid_identity_and_outside_keychain_are_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)
            for config in [{'sha1':'bad','keychain':'identity.keychain-db'},{'sha1':'A'*40,'keychain':'/tmp/other.keychain'}]:
                (folder/'identity.json').write_text(json.dumps(config))
                with self.assertRaises(ValueError):load_identity(folder)
if __name__=='__main__':unittest.main()
