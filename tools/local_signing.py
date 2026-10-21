"""Stable, private local development identity. Never silently uses ad-hoc signing."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent.parent
DEFAULT_FOLDER=Path.home()/'Library/Application Support/ContextCapturePrototype/Signing'
BUNDLE_ID='local.contextcapture.prototype'


def load_identity(folder=DEFAULT_FOLDER):
    folder=Path(folder).resolve()
    try: config=json.loads((folder/'identity.json').read_text())
    except (OSError,ValueError) as error: raise ValueError('尚未配置固定签名身份；停止构建，不退回临时签名。') from error
    if not re.fullmatch('[0-9A-Fa-f]{40}',config.get('sha1','')) or config.get('keychain')!='identity.keychain-db':
        raise ValueError('签名身份配置无效')
    keychain=folder/'identity.keychain-db'
    if not keychain.is_file() or keychain.is_symlink(): raise ValueError('固定签名钥匙串不存在或无效')
    return {'sha1':config['sha1'].upper(),'keychain':str(keychain),'folder':str(folder)}


def signing_arguments(identity,app):
    requirement='designated => identifier "'+BUNDLE_ID+'" and certificate leaf = H"'+identity['sha1']+'"'
    return ['codesign','--force','--sign',identity['sha1'],'--keychain',identity['keychain'],'--identifier',BUNDLE_ID,'--requirements','='+requirement,str(app)]


def helper():
    target=ROOT/'build/signing-keychain-helper'
    target.parent.mkdir(parents=True,exist_ok=True)
    with (target.parent/'signing-helper-build.lock').open('a') as lock:
        os.chmod(lock.name,0o600)
        fcntl.flock(lock,fcntl.LOCK_EX)
        temporary=target.with_suffix('.building')
        subprocess.run(['swiftc',str(ROOT/'tools/SigningKeychain.swift'),'-o',str(temporary)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        temporary.replace(target)
    return target


def unlock(identity):
    subprocess.run([str(helper()),'unlock',identity['folder']],check=True,stdout=subprocess.DEVNULL)


def sign(identity,app):
    result=subprocess.run([str(helper()),'sign',identity['folder']]+signing_arguments(identity,app),capture_output=True,text=True)
    if result.returncode: raise ValueError('固定签名失败：'+result.stderr.strip())

def setup(folder=DEFAULT_FOLDER):
    folder=Path(folder)
    if (folder/'identity.json').exists(): return load_identity(folder)
    folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    folder.chmod(0o700)
    if (folder/'identity.keychain-db').exists():
        if not (folder/'certificate.pem').is_file() or not (folder/'keychain-password').is_file():
            raise ValueError('固定身份尚未完整配置，未自动替换密钥。')
        publish_certificate(folder,shutil.which('openssl'))
        return finalize(folder,shutil.which('openssl'))
    key=folder/'private-key.pem';cert=folder/'certificate.pem';p12=folder/'identity.p12';wrapping=folder/'import-password'
    old_mask=os.umask(0o077)
    try:
        wrapping.write_text(secrets.token_hex(32))
        openssl=shutil.which('openssl')
        subprocess.run([openssl,'req','-new','-newkey','rsa:3072','-x509','-sha256','-days','3650','-nodes','-subj','/CN=ContextCapture Local Development/OU=Local Prototype Only','-addext','basicConstraints=critical,CA:FALSE','-addext','keyUsage=critical,digitalSignature','-addext','extendedKeyUsage=critical,codeSigning','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        subprocess.run([openssl,'pkcs12','-export','-legacy','-inkey',str(key),'-in',str(cert),'-name','ContextCapture Local Development','-out',str(p12),'-passout','file:'+str(wrapping)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        subprocess.run([openssl,'x509','-in',str(cert),'-outform','der','-out',str(folder/'certificate.cer')],check=True)
        subprocess.run([str(helper()),'create',str(folder)],check=True)
        publish_certificate(folder,openssl)
        return finalize(folder,openssl)
    finally:
        os.umask(old_mask)
        # Only generated temporary secrets, never any user documents.
        for path in [key,p12,wrapping]:
            if path.exists():path.unlink()

def publish_certificate(folder,openssl):
    if not (folder/'certificate.cer').exists():
        subprocess.run([openssl,'x509','-in',str(folder/'certificate.pem'),'-outform','der','-out',str(folder/'certificate.cer')],check=True)
    subprocess.run([str(helper()),'publish-certificate',str(folder)],check=True,stdout=subprocess.DEVNULL)

def finalize(folder,openssl):
    fingerprint=subprocess.check_output([openssl,'x509','-in',str(folder/'certificate.pem'),'-noout','-fingerprint','-sha1'],text=True).strip().split('=')[-1].replace(':','').upper()
    config={'sha1':fingerprint,'keychain':'identity.keychain-db','purpose':'local prototype development only'}
    # Sign a throwaway Mach-O before enabling this identity for normal builds.
    identity={'sha1':fingerprint,'keychain':str(folder/'identity.keychain-db'),'folder':str(folder)}
    unlock(identity)
    with tempfile.TemporaryDirectory(prefix='context-signing-check-') as d:
        target=Path(d)/'probe';shutil.copyfile('/usr/bin/true',target)
        sign(identity,target)
        subprocess.run(['codesign','--verify','--strict',str(target)],check=True,capture_output=True)
    (folder/'identity.json').write_text(json.dumps(config,indent=2)+'\n')
    (folder/'identity.json').chmod(0o600)
    return identity


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--setup',action='store_true');args=parser.parse_args()
    result=setup() if args.setup else load_identity()
    print(json.dumps({'sha1':result['sha1'],'keychain':result['keychain'],'status':'ready'}))
