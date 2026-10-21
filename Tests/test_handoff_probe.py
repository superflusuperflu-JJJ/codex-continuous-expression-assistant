import json
from pathlib import Path
import queue
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import codex_handoff_probe

class SilentTransport:
    title='Selected test'
    calls=[]
    def __init__(self,*args):pass
    def send(self,*args):pass
    def call(self,method,params):
        type(self).calls.append(method)
        if method=='thread/read':return {'thread':{'name':self.title,'status':{'type':'idle'}}}
        if method=='turn/start':return {'turn':{'id':'turn-test'}}
        return {}
    def next(self,timeout):raise queue.Empty()
    def close(self):pass

class ReceiptChecks(unittest.TestCase):
    def invoke(self,send=True):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        p=Path(temporary.name);session=p/'session';session.mkdir()
        (session/'prompt.md').write_text('只确认收到这段合成文字，不执行其他操作。')
        (session/'materials.json').write_text('[]')
        args=['probe','--session',str(session),'--thread','thread-test','--expect-title','Selected test','--output',str(p/'out'),'--codex','/not-executed']
        if send:args+=['--send']
        SilentTransport.calls=[]
        with patch.object(sys,'argv',args),patch.object(codex_handoff_probe,'RPC',SilentTransport):
            codex_handoff_probe.main()
        return json.loads((p/'out/receipt.json').read_text())
    def test_quiet_timeout_is_persisted_and_not_success(self):
        result=self.invoke()
        self.assertEqual(result['status'],'receipt-timeout')
        self.assertEqual(SilentTransport.calls.count('turn/start'),1)
    def test_dry_run_does_not_connect_or_send(self):
        result=self.invoke(send=False)
        self.assertEqual(result['status'],'prepared')
        self.assertEqual(SilentTransport.calls,[])
