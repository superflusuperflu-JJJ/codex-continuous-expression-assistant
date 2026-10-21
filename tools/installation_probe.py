"""Read-only compatibility/login probe. Never reads credential files or submits a task."""
import argparse
import json
import subprocess


def probe(executable):
    result={'compatible':False,'loggedIn':False,'version':''}
    try:
        version=subprocess.run([executable,'--version'],capture_output=True,text=True,timeout=5)
        # Parse-only help validates the flags used by organization, without execution.
        help_result=subprocess.run([executable,'exec','--ignore-user-config','--ignore-rules','--ephemeral','--sandbox','read-only','--skip-git-repo-check','--output-schema','/dev/null','--help'],capture_output=True,timeout=5)
        server=subprocess.run([executable,'app-server','--help'],capture_output=True,timeout=5)
        result['compatible']=version.returncode==help_result.returncode==server.returncode==0
        if version.returncode==0 and version.stdout.strip().startswith('codex-cli '):
            result['version']=version.stdout.strip().splitlines()[0][:80]
        login=subprocess.run([executable,'login','status'],capture_output=True,timeout=5)
        result['loggedIn']=login.returncode==0
    except (OSError,subprocess.TimeoutExpired):
        pass
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--codex',required=True);args=parser.parse_args()
    print(json.dumps(probe(args.codex)))
