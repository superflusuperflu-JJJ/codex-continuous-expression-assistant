"""Read-only Codex receipts and a local exclusive submission journal. Never sends."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import tempfile
import time
import uuid
from codex_handoff_probe import RPC


def validate(thread_id,sha):
    if str(uuid.UUID(thread_id))!=thread_id or not re.fullmatch('[0-9a-f]{64}',sha):
        raise ValueError('发送目标或内容校验无效')


def baseline(thread,thread_id,sha):
    validate(thread_id,sha)
    if thread.get('id')!=thread_id or not isinstance(thread.get('turns'),list):
        raise ValueError('无法取得所选对话的发送前记录')
    ids=[turn['id'] for turn in thread['turns'] if isinstance(turn.get('id'),str)]
    if len(ids)!=len(thread['turns']):raise ValueError('对话记录不完整')
    return {'threadID':thread_id,'sha256':sha,'beforeTurnIDs':ids,'attemptID':str(uuid.uuid4())}


def find_receipt(thread,state):
    if thread.get('id')!=state['threadID']:raise ValueError('接收对话与所选目标不一致')
    if not isinstance(thread.get('turns'),list):raise ValueError('无法核对接收记录')
    before=set(state['beforeTurnIDs'])
    for turn in thread['turns']:
        if not turn.get('id') or turn['id'] in before:continue
        for item in turn.get('items',[]):
            if item.get('type')!='userMessage':continue
            text=''.join(x.get('text','') for x in item.get('content',[]) if x.get('type')=='text')
            candidates=[text]+([text[:-1]] if text.endswith('\n') else [])
            if any(hashlib.sha256(x.encode()).hexdigest()==state['sha256'] for x in candidates):return turn['id']
    return None


def journal_path(root,thread_id,sha):
    validate(thread_id,sha)
    key=hashlib.sha256((thread_id+'\n'+sha).encode()).hexdigest()
    return Path(root)/(key+'.json')


def private_write(path,value):
    fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as out:json.dump(value,out,ensure_ascii=False)


def reserve(root,state):
    root=Path(root);root.mkdir(parents=True,exist_ok=True,mode=0o700)
    path=journal_path(root,state['threadID'],state['sha256'])
    private_write(path,{'threadID':state['threadID'],'sha256':state['sha256'],'status':'submission-attempt-reserved','attemptID':state['attemptID']})
    return path


def release(root,state):
    path=journal_path(root,state['threadID'],state['sha256'])
    value=json.loads(path.read_text())
    if any(value.get(key)!=state.get(key) for key in ['threadID','sha256','attemptID']) or value.get('status')!='submission-attempt-reserved':
        raise ValueError('无法安全解除其他尝试的发送记录')
    path.unlink()


def read_thread(executable,thread_id):
    with tempfile.TemporaryDirectory(prefix='context-send-read-') as folder:
        rpc=RPC(executable,Path(folder)/'rpc.log')
        try:
            rpc.call('initialize',{'clientInfo':{'name':'context_capture_receipt','version':'0.1'}})
            rpc.send({'method':'initialized','params':{}})
            return rpc.call('thread/read',{'threadId':thread_id,'includeTurns':True})['thread']
        finally:rpc.close()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=['baseline','reserve','release','confirm'])
    parser.add_argument('--codex',required=True);parser.add_argument('--state',required=True,type=Path)
    parser.add_argument('--journal',required=True,type=Path);parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--thread');parser.add_argument('--sha');args=parser.parse_args()
    code=0
    try:
        if args.mode=='baseline':
            if journal_path(args.journal,args.thread,args.sha).exists():
                raise ValueError('相同内容已提交或结果待核对；请先查看 Codex，不重复发送')
            state=baseline(read_thread(args.codex,args.thread),args.thread,args.sha)
            private_write(args.state,state);result={'baselineReady':True}
        else:
            state=json.loads(args.state.read_text())
            if args.mode=='reserve':
                reserve(args.journal,state);result={'reserved':True}
            elif args.mode=='release':
                release(args.journal,state);result={'released':True}
            else:
                deadline=time.monotonic()+6;turn=None
                while time.monotonic()<deadline:
                    turn=find_receipt(read_thread(args.codex,state['threadID']),state)
                    if turn:break
                    time.sleep(.3)
                result={'receiptVerified':bool(turn),'turnID':turn}
                if turn:
                    # Atomic replacement preserves the prior reservation on failure.
                    path=journal_path(args.journal,state['threadID'],state['sha256'])
                    temporary=path.with_name(path.name+'.'+str(uuid.uuid4())+'.tmp')
                    private_write(temporary,{'threadID':state['threadID'],'sha256':state['sha256'],'status':'received','turnID':turn})
                    temporary.replace(path)
    except FileExistsError:result={'error':'相同内容已提交或结果待核对，不重复发送'};code=1
    except Exception as error:result={'error':str(error)};code=1
    private_write(args.output,result)
    return code

if __name__=='__main__':
    # Swift terminates this helper on timeout. Raise through read_thread's finally,
    # which closes and waits for its read-only app-server child before exiting.
    def terminate(signum,frame):raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,terminate)
    raise SystemExit(main())
