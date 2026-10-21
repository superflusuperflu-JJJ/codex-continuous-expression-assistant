from pathlib import Path
import shlex
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from installation_probe import probe

class InstallationProbeChecks(unittest.TestCase):
    def fixture(self,folder,unsupported=False):
        log=folder/'calls';cli=folder/'codex'
        body='#!/bin/sh\nprintf "%s\\n" "$*" >> '+shlex.quote(str(log))+'\n'
        body+='if [ "$1" = "--version" ]; then echo "codex-cli fixture"; exit 0; fi\n'
        if unsupported:body+='if [ "$1" = "exec" ]; then exit 2; fi\n'
        body+='exit 0\n';cli.write_text(body);cli.chmod(0o700)
        return cli,log
    def test_only_local_status_and_parse_only_help_are_requested(self):
        with tempfile.TemporaryDirectory() as d:
            cli,log=self.fixture(Path(d));result=probe(str(cli))
            self.assertTrue(result['compatible']);self.assertTrue(result['loggedIn'])
            calls=log.read_text().splitlines()
            self.assertEqual(len(calls),4)
            self.assertIn('login status',calls)
            self.assertTrue(next(c for c in calls if c.startswith('exec ')).endswith('--help'))
            self.assertEqual(next(c for c in calls if c.startswith('app-server')),'app-server --help')
            self.assertNotIn('login',calls)
    def test_incompatible_cli_does_not_pass_even_if_logged_in(self):
        with tempfile.TemporaryDirectory() as d:
            cli,_=self.fixture(Path(d),unsupported=True)
            result=probe(str(cli));self.assertFalse(result['compatible']);self.assertTrue(result['loggedIn'])
    def test_missing_executable_is_pending_not_ready(self):
        result=probe('/nonexistent-test-codex')
        self.assertFalse(result['compatible']);self.assertFalse(result['loggedIn'])
