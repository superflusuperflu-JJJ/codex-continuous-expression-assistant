#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
swift run -debug-info-format none CoreChecks
swift run -debug-info-format none ContextCapture --self-test
node --test Tests/browser-*.test.cjs
node --check BrowserExtension/content.js
python3 -m py_compile tools/build.py tools/native_host.py tools/handoff_package.py tools/codex_handoff_probe.py tools/prepare_desktop_draft.py tools/codex_conversations.py tools/local_signing.py tools/desktop_send_receipt.py
python3 -m unittest discover -s Tests -p 'test_*.py'
