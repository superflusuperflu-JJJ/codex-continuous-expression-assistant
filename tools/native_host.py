import json
from pathlib import Path
import socket
import struct
import sys

SOCKET = str(Path.home() / 'Library/Application Support/ContextCapturePrototype/bridge.sock')

def read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            return None
        result.extend(chunk)
    return bytes(result)

def main():
    while True:
        header = read_exact(sys.stdin.buffer, 4)
        if header is None:
            return
        length = struct.unpack('<I', header)[0]
        if length > 12 * 1024 * 1024:
            return
        data = read_exact(sys.stdin.buffer, length)
        if data is None:
            return
        try:
            request = json.loads(data)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(5)
                connection.connect(SOCKET)
                connection.sendall(json.dumps(request, ensure_ascii=False).encode() + b'\n')
                response = bytearray()
                while b'\n' not in response:
                    chunk = connection.recv(65536)
                    if not chunk:
                        raise ConnectionError('应用未回应')
                    response.extend(chunk)
                    if len(response) > 1024 * 1024:
                        raise ValueError('回应过大')
                result = json.loads(response.split(b'\n')[0])
        except Exception:
            result = {'active': False, 'error': '请先打开 Codex连续表达助手'}
        encoded = json.dumps(result, ensure_ascii=False).encode()
        sys.stdout.buffer.write(struct.pack('<I', len(encoded)) + encoded)
        sys.stdout.buffer.flush()

if __name__ == '__main__':
    main()
