"""Exercise publication failures and retries without network, signing keys or real releases."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[2] / 'publish.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
history_spec = importlib.util.spec_from_file_location('release_feed', Path(__file__).resolve().parents[2] / 'release_feed.py')
history = importlib.util.module_from_spec(history_spec)
history_spec.loader.exec_module(history)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='qgt-publish-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '1.5.7', 'CFBundleVersion': '14'}))
        (self.root / 'Publication').mkdir()
        (self.root / 'Publication/RELEASE.md').write_text('Version 1.5.7 notes')
        (self.root / 'Publication/README.md').write_text('Product introduction')
        folder = self.root / 'dist/updates'
        folder.mkdir(parents=True)
        self.archive = folder / 'QuickGoogleTranslate-1.5.7.zip'
        self.delta = folder / 'QuickGoogleTranslate-14-13.delta'
        self.archive.write_bytes(b'full archive fixture')
        self.delta.write_bytes(b'delta fixture')
        # These unrelated historical assets must never be uploaded into v1.5.7.
        (folder / 'QuickGoogleTranslate-1.5.6.zip').write_bytes(b'old archive')
        (folder / 'QuickGoogleTranslate-13-12.delta').write_bytes(b'old delta')
        feed = ET.Element('rss')
        channel = ET.SubElement(feed, 'channel')
        current = ET.SubElement(channel, 'item')
        ET.SubElement(current, f'{{{publisher.NS}}}version').text = '14'
        ET.SubElement(current, f'{{{publisher.NS}}}shortVersionString').text = '1.5.7'
        deltas = ET.SubElement(current, f'{{{publisher.NS}}}deltas')
        self.enclosure = ET.SubElement(current, 'enclosure', self.attributes(self.archive))
        ET.SubElement(deltas, 'enclosure', {
            **self.attributes(self.delta), f'{{{publisher.NS}}}deltaFrom': '13'})
        old = ET.SubElement(channel, 'item')
        ET.SubElement(old, f'{{{publisher.NS}}}version').text = '13'
        ET.SubElement(old, f'{{{publisher.NS}}}shortVersionString').text = '1.5.6'
        ET.SubElement(old, 'enclosure', {
            'url': f'https://github.com/{publisher.REPO}/releases/download/updates/QuickGoogleTranslate-1.5.6.zip'})
        self.tree = ET.ElementTree(feed)
        self.feed = folder / 'appcast.xml'
        self.save_feed()
        self.calls = []
        self.puts = []
        self.existing = None
        self.fail_upload = False

    def attributes(self, path):
        return {'url': f'https://github.com/{publisher.REPO}/releases/download/v1.5.7/{path.name}',
                'length': str(path.stat().st_size), f'{{{publisher.NS}}}edSignature': 'fixture-signature'}

    def save_feed(self):
        self.tree.write(self.feed)

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        stdout, stderr, code = '', '', 0
        if args[0] == 'fixture-gh':
            if args[1] == 'api':
                if '/releases/tags/' in args[2]:
                    if self.existing is None:
                        stderr, code = 'HTTP 404', 1
                    else:
                        stdout = json.dumps(self.existing)
                elif '/contents/' in args[2]:
                    stderr, code = 'HTTP 404', 1
            elif args[1:3] == ['release', 'upload'] and self.fail_upload:
                raise subprocess.CalledProcessError(1, args)
            elif args[1:3] == ['release', 'download']:
                pattern = args[args.index('--pattern') + 1]
                output = Path(args[args.index('--output') + 1])
                output.write_bytes((self.feed.parent / pattern).read_bytes())
        return subprocess.CompletedProcess(args, code, stdout, stderr)

    def fake_output(self, args, **kwargs):
        self.calls.append(args)
        if args[1:3] == ['api', 'user']:
            return 'Foolishgod'
        if args[1:3] == ['repo', 'view']:
            return json.dumps({'visibility': 'PUBLIC', 'defaultBranchRef': {'name': 'main'}})
        if args[1:4] == ['api', '--method', 'PUT']:
            body = json.loads(Path(args[-1]).read_text())
            self.puts.append((args[4], base64.b64decode(body['content'])))
            return '{}'
        raise AssertionError('Unexpected command: ' + str(args))

    def publish(self, sync=False):
        with patch.object(publisher.subprocess, 'run', side_effect=self.fake_run), \
                patch.object(publisher.subprocess, 'check_output', side_effect=self.fake_output):
            publisher.publish(self.root, 'fixture-gh', sync)

    def release_calls(self, action):
        return [args for args in self.calls if args[:3] == ['fixture-gh', 'release', action]]

    def remote_assets(self):
        return [{'name': path.name, 'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}
                for path in (self.archive, self.delta)]

    def test_new_version_is_draft_then_uploaded_then_public_then_feed(self):
        original_feed = self.feed.read_bytes()
        self.publish()
        create = self.release_calls('create')[0]
        self.assertEqual(create[3], 'v1.5.7')
        self.assertIn('--draft', create)
        self.assertIn('划词谷歌翻译 1.5.7', create)
        self.assertEqual({Path(args[4]).name for args in self.release_calls('upload')},
                         {self.archive.name, self.delta.name})
        edit = self.release_calls('edit')[0]
        self.assertIn('--draft=false', edit)
        put = next(args for args in self.calls if args[1:4] == ['api', '--method', 'PUT'])
        self.assertLess(self.calls.index(self.release_calls('upload')[-1]), self.calls.index(edit))
        self.assertLess(self.calls.index(edit), self.calls.index(put))
        self.assertEqual(self.puts, [(f'repos/{publisher.REPO}/contents/appcast.xml', original_feed)])
        self.assertEqual(self.feed.read_bytes(), original_feed)
        self.assertTrue(all(args[3] == 'v1.5.7' for args in self.release_calls('upload')))

    def test_published_retry_verifies_assets_without_editing_release(self):
        self.existing = {'draft': False, 'assets': self.remote_assets()}
        self.publish()
        self.assertFalse(self.release_calls('create'))
        self.assertFalse(self.release_calls('upload'))
        self.assertFalse(self.release_calls('edit'))

    def test_draft_retry_uploads_only_missing_assets(self):
        self.existing = {'draft': True, 'assets': self.remote_assets()[:1]}
        self.publish()
        self.assertEqual(len(self.release_calls('upload')), 1)
        self.assertEqual(Path(self.release_calls('upload')[0][4]).name, self.delta.name)
        self.assertTrue(self.release_calls('edit'))

    def test_digest_missing_downloads_and_compares_existing_assets(self):
        self.existing = {'draft': False, 'assets': [{'name': path.name} for path in (self.archive, self.delta)]}
        self.publish()
        self.assertEqual(len(self.release_calls('download')), 2)
        self.assertFalse(self.release_calls('upload'))

    def test_changed_released_bytes_abort_before_uploads_or_feed(self):
        self.existing = {'draft': True, 'assets': [{'name': self.delta.name, 'digest': 'sha256:changed'}]}
        with self.assertRaisesRegex(RuntimeError, 'Released asset changed'):
            self.publish()
        self.assertFalse(self.release_calls('upload'))
        self.assertFalse(self.puts)

    def test_failed_upload_keeps_release_draft_and_feed_unannounced(self):
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertFalse(self.release_calls('edit'))
        self.assertFalse(self.puts)

    def test_legacy_current_url_rejected_before_remote_mutation(self):
        self.enclosure.set('url', self.enclosure.get('url').replace('/v1.5.7/', '/updates/'))
        self.save_feed()
        with self.assertRaisesRegex(RuntimeError, 'this version release'):
            self.publish()
        self.assertFalse(self.calls)

    def test_missing_or_changed_package_rejected_before_remote_mutation(self):
        self.delta.write_bytes(b'changed size')
        with self.assertRaisesRegex(RuntimeError, 'incorrect update asset'):
            self.publish()
        self.assertFalse(self.calls)

    def test_incomplete_public_release_cannot_be_extended(self):
        self.existing = {'draft': False, 'assets': self.remote_assets()[:1]}
        with self.assertRaisesRegex(RuntimeError, 'Published release is incomplete'):
            self.publish()
        self.assertFalse(self.release_calls('upload'))
        self.assertFalse(self.puts)

    def test_generator_changes_to_old_urls_are_restored_before_signing(self):
        previous = self.root / 'previous.xml'
        previous.write_bytes(self.feed.read_bytes())
        historical_item = self.tree.findall('./channel/item')[1]
        expected = ET.tostring(historical_item)
        historical_item.find('enclosure').set('url', 'https://invalid.example/new-release/old.zip')
        ET.SubElement(historical_item, 'description').text = 'Regenerated notes'
        current = ET.tostring(self.tree.findall('./channel/item')[0])
        history.preserve_history(self.tree, previous, '14')
        self.assertEqual(ET.tostring(self.tree.findall('./channel/item')[1]), expected)
        self.assertEqual(ET.tostring(self.tree.findall('./channel/item')[0]), current)

    def test_history_restoration_respects_pruning_and_empty_first_feed(self):
        previous = self.root / 'previous.xml'
        previous.write_bytes(self.feed.read_bytes())
        self.tree.find('channel').remove(self.tree.findall('./channel/item')[1])
        history.preserve_history(self.tree, previous, '14')
        self.assertEqual(len(self.tree.findall('./channel/item')), 1)
        previous.write_bytes(b'')
        history.preserve_history(self.tree, previous, '14')
        self.assertEqual(len(self.tree.findall('./channel/item')), 1)

    def test_readme_sync_is_explicit(self):
        self.publish(sync=True)
        self.assertEqual(self.puts[-1], (f'repos/{publisher.REPO}/contents/README.md', b'Product introduction'))


if __name__ == '__main__':
    unittest.main()
