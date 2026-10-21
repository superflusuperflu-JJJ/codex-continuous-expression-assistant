"""One-shot desktop handoff experiment, not the prototype's production send UI.
Uses the installed CLI's documented app-server JSON-RPC, never desktop private credentials.
"""
import argparse
import hashlib
import json
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid
from handoff_package import prepare_package

class RPC:
    def __init__(self,executable,log):
        self.stderr = open(log,'w')
        self.process = subprocess.Popen([executable,'app-server','--listen','stdio://'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.stderr,text=True,bufsize=1)
        self.messages = queue.Queue(); self.serial = 0
        threading.Thread(target=self._read,daemon=True).start()
    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        finally: self.messages.put(None)
    def send(self,value):
        self.process.stdin.write(json.dumps(value,ensure_ascii=False)+'\n'); self.process.stdin.flush()
    def next(self,timeout=30):
        value=self.messages.get(timeout=timeout)
        if value is None: raise RuntimeError('Codex app-server connection closed; see app-server.log')
        if 'method' in value and 'id' in value:
            # No runtime approvals or tool-side effects are silently accepted by the probe.
            self.send({'id':value['id'],'error':{'code':-32601,'message':'Handoff probe does not approve runtime requests'}})
        return value
    def call(self,method,params):
        self.serial+=1; request_id=self.serial
        self.send({'id':request_id,'method':method,'params':params})
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            message=self.next(max(.1,deadline-time.monotonic()))
            if message.get('id')==request_id and 'method' not in message:
                if 'error' in message: raise RuntimeError(json.dumps(message['error'],ensure_ascii=False))
                return message['result']
        raise TimeoutError(method+' timed out')
    def close(self):
        self.process.stdin.close()
        try:self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:self.process.terminate();self.process.wait(timeout=5)
        self.stderr.close()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--session',required=True,type=Path)
    parser.add_argument('--thread',required=True)
    parser.add_argument('--expect-title',required=True)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--codex',required=True)
    parser.add_argument('--send',action='store_true',help='Start exactly one receipt-only test turn in the explicitly selected thread')
    args=parser.parse_args()
    package=prepare_package(args.session)
    args.output.mkdir(parents=True,exist_ok=True,mode=0o700)
    request_id='context-capture-'+str(uuid.uuid4())
    wrapper=('这是连续表达原型的接收测试，不执行下方 Prompt 的实际任务，不修改项目、不联网。'
        '请仅确认收到，并列出识别到的任务要求及素材编号，不要复述邀请码。'
        '若下方明确写了“合成素材验收”，仅允许按该验收要求读取所列测试文件、辨认测试图像。\n'
        '测试编号：'+request_id+'\n\n<approved_prompt>\n'+package['text']+'\n</approved_prompt>')
    inputs=[{'type':'text','text':wrapper}]+package['inputs']
    params={'threadId':args.thread,'clientUserMessageId':request_id,'input':inputs,
        'sandboxPolicy':{'type':'readOnly'},'approvalPolicy':'never'}
    (args.output/'request.json').write_text(json.dumps(params,ensure_ascii=False,indent=2))
    summary={'requestID':request_id,'threadID':args.thread,'materialIDs':package['materialIDs'],
        'imageCount':len(package['inputs']),'payloadSHA256':hashlib.sha256(package['text'].encode()).hexdigest(),
        'status':'prepared'}
    (args.output/'receipt.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
    if not args.send:
        print(json.dumps(summary,ensure_ascii=False));return
    rpc=RPC(args.codex,args.output/'app-server.log')
    try:
        rpc.call('initialize',{'clientInfo':{'name':'context_capture_handoff_probe','title':'连续表达联通验证','version':'0.1'}})
        rpc.send({'method':'initialized','params':{}})
        thread=rpc.call('thread/read',{'threadId':args.thread,'includeTurns':False})['thread']
        if thread.get('name')!=args.expect_title:raise ValueError('Target thread title mismatch; no message sent')
        if thread.get('status',{}).get('type') not in ('idle','notLoaded'):raise ValueError('Target is busy; no message sent')
        rpc.call('thread/resume',{'threadId':args.thread,'excludeTurns':True})
        summary['status']='submission-in-flight'
        turn=rpc.call('turn/start',params)['turn']; summary.update(turnID=turn['id'],status='accepted')
        (args.output/'receipt.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
        print(json.dumps(summary,ensure_ascii=False),flush=True)
        deadline=time.monotonic()+120
        with (args.output/'events.jsonl').open('w') as log:
            while time.monotonic()<deadline:
                try:event=rpc.next(max(.1,deadline-time.monotonic()))
                except queue.Empty:
                    summary['status']='receipt-timeout';break
                log.write(json.dumps(event,ensure_ascii=False)+'\n');log.flush()
                if event.get('method')=='turn/completed' and event.get('params',{}).get('turn',{}).get('id')==turn['id']:
                    summary['status']=event['params']['turn']['status'];break
            else:summary['status']='receipt-timeout'
        (args.output/'receipt.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
        print(json.dumps(summary,ensure_ascii=False),flush=True)
    except Exception as error:
        summary['status']='delivery-unconfirmed' if summary['status'] in ('submission-in-flight','accepted') else 'not-sent'
        summary['error']=str(error)
        (args.output/'receipt.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
        raise
    finally:rpc.close()

if __name__=='__main__':main()
