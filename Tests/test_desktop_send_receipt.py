import json
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from desktop_send_receipt import baseline, find_receipt, reserve, journal_path, read_thread, release
A='00000000-0000-4000-8000-000000000002'
B='00000000-0000-4000-8000-000000000001'
TEXT='按我编辑后的要求处理 [M1]。'
SHA=hashlib.sha256(TEXT.encode()).hexdigest()
def thread(turn_id='old',text=TEXT,id=A):
 return {'id':id,'turns':[{'id':turn_id,'items':[{'type':'userMessage','content':[{'type':'text','text':text}]}]}]}
class ReceiptChecks(unittest.TestCase):
 def test_old_identical_message_does_not_count_as_receipt(self):
  before=baseline(thread(),A,SHA)
  self.assertIsNone(find_receipt(thread(),before))
 def test_only_matching_target_can_be_confirmed(self):
  before=baseline(thread(),A,SHA)
  with self.assertRaises(ValueError):find_receipt(thread('new',id=B),before)
 def test_new_exact_message_and_renderer_terminal_lf_are_accepted(self):
  before=baseline(thread(),A,SHA)
  for text in [TEXT,TEXT+'\n']:
   self.assertEqual(find_receipt(thread('new',text),before),'new')
 def test_edits_or_multiple_extra_lf_are_not_normalized_away(self):
  before=baseline(thread(),A,SHA)
  for text in [TEXT+'改',TEXT+'\n\n',TEXT+' ']:
   self.assertIsNone(find_receipt(thread('new',text),before))
 def test_reservation_is_private_exclusive_and_target_bound(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder)/'journal';before=baseline(thread(),A,SHA)
   path=reserve(root,before)
   self.assertEqual(os.stat(path).st_mode & 0o777,0o600)
   with self.assertRaises(FileExistsError):reserve(root,before)
   self.assertNotEqual(journal_path(root,A,SHA),journal_path(root,B,SHA))
 def test_only_own_unpressed_reservation_can_be_released(self):
  with tempfile.TemporaryDirectory() as folder:
   before=baseline(thread(),A,SHA);path=reserve(folder,before)
   other=baseline(thread(),A,SHA)
   with self.assertRaises(ValueError):release(folder,other)
   self.assertTrue(path.exists())
   release(folder,before)
   self.assertFalse(path.exists())
   reserve(folder,other)
 def test_received_journal_cannot_be_released(self):
  with tempfile.TemporaryDirectory() as folder:
   before=baseline(thread(),A,SHA);path=reserve(folder,before)
   value=json.loads(path.read_text());value['status']='received';path.write_text(json.dumps(value))
   with self.assertRaises(ValueError):release(folder,before)
   self.assertTrue(path.exists())
 def test_missing_history_cannot_produce_valid_baseline(self):
  with self.assertRaises(ValueError):baseline({'id':A},A,SHA)
 def test_history_transport_never_resumes_or_submits(self):
  class ReadOnlyServer:
   calls=[]
   def __init__(self,*args):pass
   def call(self,method,params):
    self.calls.append((method,params))
    if method=='initialize':return {}
    if method=='thread/read':return {'thread':thread()}
    raise AssertionError('unexpected mutation '+method)
   def send(self,value):
    if value!={'method':'initialized','params':{}}:raise AssertionError('unexpected request')
   def close(self):pass
  with patch('desktop_send_receipt.RPC',ReadOnlyServer):
   self.assertEqual(read_thread('unused',A)['id'],A)
  self.assertEqual(ReadOnlyServer.calls[-1],('thread/read',{'threadId':A,'includeTurns':True}))
if __name__=='__main__':unittest.main()
