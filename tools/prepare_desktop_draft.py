"""Local-only preparation from the reviewed editor snapshot. Never contacts Codex."""
import json
import os
from pathlib import Path
import sys
from handoff_package import prepare_package


def main():
    request_path, output_path = map(Path, sys.argv[1:3])
    try:
        request = json.loads(request_path.read_text())
        result = prepare_package(request['session'], canonical=request['prompt'], material_records=request['materials'])
        code = 0
    except Exception as error:
        result = {'error': str(error)}
        code = 1
    data = json.dumps(result, ensure_ascii=False)
    fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as out:
        out.write(data)
    return code


if __name__ == '__main__':
    sys.exit(main())
