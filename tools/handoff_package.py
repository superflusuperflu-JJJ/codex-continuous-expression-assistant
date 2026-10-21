"""Build a handoff from the approved editor text, excluding unassigned materials.

This probe supports the current prototype's plain-text material index format.
It never re-runs semantic composition or reads unreferenced attachment contents.
"""
import json
from pathlib import Path
import re

HEADINGS = {'对应素材', '另外选中的资料（尚未指定用途）', '采集需核对'}
ENTRY = re.compile(r'^\[(M[0-9]+)\] (文字|链接|文件|图片)：',re.MULTILINE)
REFERENCE = re.compile(r'\[(M[0-9]+)\]')

def prepare_package(session, *, canonical=None, material_records=None):
    session = Path(session).resolve()
    if canonical is None: canonical = (session/'prompt.md').read_text()
    lines = canonical.splitlines(keepends=True)
    boundary = next((i for i,line in enumerate(lines) if line.strip() in HEADINGS),len(lines))
    body = ''.join(lines[:boundary]).strip()
    if not body or '【待选择' in body or re.search(r'^待确认\s*$',body,re.MULTILINE):
        raise ValueError('正文为空或仍有待选择项目，请先完成编辑。')
    ids = list(dict.fromkeys(REFERENCE.findall(body)))
    if material_records is None: material_records = json.loads((session/'materials.json').read_text())
    materials = {m['id']:m for m in material_records}
    # Only the assigned-material section is eligible, never the unassigned tail.
    tail = ''.join(lines[boundary:])
    tail_lines = tail.splitlines(keepends=True)
    if tail_lines and tail_lines[0].strip() == '对应素材':
        stop = next((i for i,line in enumerate(tail_lines[1:],1) if line.strip() in HEADINGS),len(tail_lines))
        index = ''.join(tail_lines[1:stop])
    else:
        index = ''
    matches = list(ENTRY.finditer(index))
    entries = {}; entry_kinds = {}
    for i,match in enumerate(matches):
        material_id = match.group(1)
        if material_id in entries: raise ValueError('素材索引存在重复编号：'+material_id)
        entry_kinds[material_id] = match.group(2)
        entries[material_id] = index[match.start():matches[i+1].start() if i+1<len(matches) else len(index)].strip()
    descriptions, inputs = [], []
    for material_id in ids:
        if material_id not in materials or material_id not in entries:
            raise ValueError('正文引用的素材缺少当前索引，未自动恢复：'+material_id)
        item = materials[material_id]
        description = entries[material_id]
        if entry_kinds[material_id] == item['kind'] and item['kind'] in ('图片','文件') and item.get('localPath'):
            path = Path(item['localPath']).resolve()
            if not path.is_relative_to(session/'assets') or not path.is_file():
                raise ValueError('引用的素材副本不可用：'+material_id)
            description += '\n本机素材副本（['+material_id+']）：'+str(path)
            if item['kind']=='图片': inputs.append({'type':'localImage','path':str(path)})
        descriptions.append(description)
    text = body + ('\n\n对应素材\n\n'+'\n\n'.join(descriptions) if descriptions else '')
    return {'text':text,'materialIDs':ids,'inputs':inputs}
