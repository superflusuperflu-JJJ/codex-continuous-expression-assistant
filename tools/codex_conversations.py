"""Read local conversation metadata only. No resume, turn/start, title mutation or message contents."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import uuid
from codex_handoff_probe import RPC


def normalize_threads(records):
    result=[]; seen=set()
    for row in records:
        try:
            thread_id=str(uuid.UUID(row['id']))
            if thread_id in seen: continue
            name=row.get('name')
            if not isinstance(name,str) or not name.strip(): name='未命名对话'
            cwd=row.get('cwd') or ''
            if not isinstance(cwd,str): continue
            updated=row.get('updatedAt') or 0
            if not isinstance(updated,(int,float)): continue
            result.append({'id':thread_id,'name':name,'cwd':cwd,'updatedAt':updated})
            seen.add(thread_id)
        except (KeyError,ValueError,TypeError): continue
    return result


def list_page(rpc,cursor=None):
    params={'limit':25,'sortKey':'updated_at','archived':False,'useStateDbOnly':True,'sourceKinds':['cli','vscode','appServer']}
    if cursor: params['cursor']=cursor
    page=rpc.call('thread/list',params)
    return {'threads':normalize_threads(page.get('data',[])),'nextCursor':page.get('nextCursor')}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--codex',required=True);parser.add_argument('--output',required=True,type=Path);parser.add_argument('--cursor');args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='context-catalog-') as folder:
        rpc=RPC(args.codex,Path(folder)/'rpc.log')
        try:
            rpc.call('initialize',{'clientInfo':{'name':'context_capture_catalog','version':'0.1'}})
            rpc.send({'method':'initialized','params':{}})
            result=list_page(rpc,args.cursor)
        finally: rpc.close()
    fd=os.open(args.output,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as out:json.dump(result,out,ensure_ascii=False)

if __name__=='__main__':main()
