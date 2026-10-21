import json
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from handoff_package import prepare_package

class PackageChecks(unittest.TestCase):
    def session(self,folder,prompt,materials):
        (folder/'prompt.md').write_text(prompt)
        (folder/'materials.json').write_text(json.dumps(materials))
        return folder
    def test_only_body_references_select_materials_and_preserve_manual_text(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.session(Path(d),'我手动改过：只精简 [M1]，不要改文件。\n\n对应素材\n\n[M1] 文字：修改过的素材文字\n\n[M2] 文字：不应发送\n\n另外选中的资料（尚未指定用途）\n\n[M3] 文件：/not-sent.txt',[
                {'id':'M1','kind':'文字','content':'原始内容'}, {'id':'M2','kind':'文字','content':'不应发送'}, {'id':'M3','kind':'文件','content':'/not-sent.txt'}])
            result=prepare_package(p)
            self.assertEqual(result['materialIDs'],['M1'])
            self.assertIn('我手动改过：只精简 [M1]，不要改文件。',result['text'])
            self.assertIn('修改过的素材文字',result['text'])
            self.assertNotIn('不应发送',result['text'])
            self.assertNotIn('/not-sent.txt',result['text'])
            self.assertNotIn('原始内容',result['text'])
    def test_materials_with_no_reference_are_not_sent(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.session(Path(d),'只处理我这句话。\n\n另外选中的资料（尚未指定用途）\n\n[M1] 图片：秘密图片', [{'id':'M1','kind':'图片','localPath':'/unread.png'}])
            result=prepare_package(p)
            self.assertEqual(result['text'],'只处理我这句话。')
            self.assertEqual(result['inputs'],[])
    def test_missing_or_deleted_material_entry_does_not_silently_return(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.session(Path(d),'参考 [M1]。',[{'id':'M1','kind':'文字','content':'已删内容'}])
            with self.assertRaises(ValueError): prepare_package(p)
    def test_only_referenced_image_is_attached_with_absolute_path(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d); assets=folder/'assets';assets.mkdir();image=assets/'image.png';image.write_bytes(b'fixture')
            p=self.session(folder,'参考 [M1] 图片布局。\n\n对应素材\n\n[M1] 图片：截图（assets/image.png）\n\n另外选中的资料（尚未指定用途）\n\n[M2] 图片：其他',[
                {'id':'M1','kind':'图片','localPath':str(image),'availability':'excerpt'}, {'id':'M2','kind':'图片','localPath':'/unread.png'}])
            result=prepare_package(p)
            self.assertEqual(result['inputs'],[{'type':'localImage','path':str(image.resolve())}])
            self.assertNotIn('其他',result['text'])
    def test_selected_file_and_link_keep_useful_local_references(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d);(folder/'assets').mkdir();f=folder/'assets/reference.txt';f.write_text('reference')
            p=self.session(folder,'参考文件 [M1] 和链接 [M2]，不要修改原文件。\n\n对应素材\n\n[M1] 文件：/original/reference.txt（assets/reference.txt）\n\n[M2] 链接：https://example.com/docs',[
                {'id':'M1','kind':'文件','localPath':str(f)}, {'id':'M2','kind':'链接','content':'https://example.com/docs'}])
            result=prepare_package(p)
            self.assertIn(str(f),result['text']);self.assertIn('https://example.com/docs',result['text'])
            self.assertIn('不要修改原文件',result['text']);self.assertEqual(result['inputs'],[])
    def test_unresolved_placeholder_cannot_be_sent_as_approved(self):
        with tempfile.TemporaryDirectory() as d:
            p=self.session(Path(d),'【待选择 · item】哪个软件？',[])
            with self.assertRaises(ValueError):prepare_package(p)


class CanonicalAttachmentChecks(unittest.TestCase):
    def test_replacing_image_entry_with_text_does_not_send_original_image(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'assets').mkdir();image=p/'assets/original.png';image.write_bytes(b'fixture')
            (p/'prompt.md').write_text('参考 [M1]。\n\n对应素材\n\n[M1] 文字：我已经用这段话替换图片，不发送原图。')
            (p/'materials.json').write_text(json.dumps([{'id':'M1','kind':'图片','localPath':str(image)}]))
            result=prepare_package(p)
            self.assertEqual(result['inputs'],[])
            self.assertNotIn(str(image.resolve()),result['text'])
            self.assertIn('我已经用这段话替换图片',result['text'])

class EditorSnapshotChecks(unittest.TestCase):
    def test_live_editor_snapshot_wins_over_stale_saved_prompt_and_materials(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)
            (folder/'prompt.md').write_text('旧正文引用 [M2]。')
            (folder/'materials.json').write_text('[]')
            result=prepare_package(folder, canonical='我手动改过，只精简 [M1]。\n\n对应素材\n\n[M1] 文字：最新文字',material_records=[{'id':'M1','kind':'文字','content':'最新文字'}])
            self.assertIn('我手动改过，只精简 [M1]。', result['text'])
            self.assertEqual(result['materialIDs'],['M1'])
            self.assertNotIn('旧正文',result['text'])

    def test_deleted_reference_in_live_editor_does_not_return_saved_material(self):
        with tempfile.TemporaryDirectory() as d:
            result=prepare_package(Path(d),canonical='只处理这句话。',material_records=[{'id':'M1','kind':'图片','localPath':'/missing.png'}])
            self.assertEqual(result['text'],'只处理这句话。')
            self.assertEqual(result['inputs'],[])

class DesktopPreparationCLIChecks(unittest.TestCase):
    def test_prepares_current_editor_without_changing_saved_session(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d); session=folder/'session'; session.mkdir()
            (session/'prompt.md').write_text('旧正文')
            request=folder/'request.json'; output=folder/'output.json'
            request.write_text(json.dumps({'session':str(session),'prompt':'精简 [M1]。\n\n对应素材\n\n[M1] 文字：新文字\n\n另外选中的资料（尚未指定用途）\n\n[M2] 图片：不带走','materials':[{'id':'M1','kind':'文字'},{'id':'M2','kind':'图片'}]}))
            result=subprocess.run([sys.executable,str(Path(__file__).resolve().parents[1]/'tools/prepare_desktop_draft.py'),str(request),str(output)],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            package=json.loads(output.read_text())
            self.assertEqual(package['materialIDs'],['M1'])
            self.assertIn('新文字',package['text']);self.assertNotIn('不带走',package['text'])
            self.assertEqual((session/'prompt.md').read_text(),'旧正文')
            self.assertEqual(output.stat().st_mode & 0o777,0o600)

    def test_unresolved_current_editor_produces_error_instead_of_draft(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d);request=folder/'request.json';output=folder/'output.json'
            request.write_text(json.dumps({'session':d,'prompt':'【待选择 · a】','materials':[]}))
            result=subprocess.run([sys.executable,str(Path(__file__).resolve().parents[1]/'tools/prepare_desktop_draft.py'),str(request),str(output)],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('error',json.loads(output.read_text()))
            self.assertNotIn('text',json.loads(output.read_text()))

if __name__=='__main__':unittest.main()
