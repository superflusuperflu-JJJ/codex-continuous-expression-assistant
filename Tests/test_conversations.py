import unittest
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from codex_conversations import normalize_threads, list_page

A='00000000-0000-4000-8000-000000000002'
B='00000000-0000-4000-8000-000000000001'
class CatalogChecks(unittest.TestCase):
    def test_duplicate_ids_are_deduplicated_but_same_names_remain_distinct(self):
        data=[{'id':A,'name':'同名','cwd':'/one','updatedAt':2},{'id':A,'name':'同名','cwd':'/one','updatedAt':2},{'id':B,'name':'同名','cwd':'/two','updatedAt':1}]
        result=normalize_threads(data)
        self.assertEqual([x['id'] for x in result],[A,B])
        self.assertEqual(result[1]['cwd'],'/two')
    def test_invalid_records_are_rejected_and_no_preview_content_returned(self):
        data=[{'id':'bad','name':'a'},{'id':A,'name':'title','preview':'private body','cwd':'/one','updatedAt':1}]
        result=normalize_threads(data)
        self.assertEqual(len(result),1);self.assertNotIn('preview',result[0])
    def test_page_requests_only_read_only_history_with_cursor(self):
        class Server:
            def call(self,method,params):
                if method!='thread/list': raise AssertionError('unexpected mutation '+method)
                self.params=params
                return {'data':[{'id':A,'name':'a','cwd':'/one','updatedAt':1}],'nextCursor':'next'}
        server=Server();result=list_page(server,'cursor')
        self.assertEqual(result['nextCursor'],'next')
        self.assertEqual(server.params['cursor'],'cursor')
        self.assertTrue(server.params['useStateDbOnly'])
        self.assertFalse(server.params['archived'])
if __name__=='__main__':unittest.main()
