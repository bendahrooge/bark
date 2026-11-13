import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

MODULE = Path(__file__).resolve().parents[2] / 'engine/chromium/overlay/rebrand_strings.py'
spec = importlib.util.spec_from_file_location('bark_branding', MODULE)
branding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branding)


class BrandingTests(unittest.TestCase):
    def test_product_text(self):
        self.assertEqual(branding.rebrand_text('IDS_DEFAULT_BROWSER_INFOBAR_TEXT',
                         "Chromium isn't your default browser"), "Bark isn't your default browser")

    def test_translated_context_and_placeholders(self):
        self.assertEqual(branding.rebrand_text('IDS_SETTINGS', '将Chromium设为默认浏览器 $1'),
                         '将Bark设为默认浏览器 $1')

    def test_legal_attribution_is_preserved(self):
        for name in ['IDS_VERSION_UI_LICENSE', 'IDS_ABOUT_VERSION_COPYRIGHT', 'IDS_CREDITS']:
            self.assertEqual(branding.rebrand_text(name, 'The Chromium project'), 'The Chromium project')
        self.assertEqual(branding.rebrand_text('IDS_UNKNOWN', 'The Chromium Authors'), 'The Chromium Authors')

    def test_urls_and_technical_names_stay_exact(self):
        value = 'Chromium: https://example.test/Chromium?q=Chromium ChromiumFeature chromium://flags'
        self.assertEqual(branding.rebrand_text('IDS_HELP', value),
                         'Bark: https://example.test/Chromium?q=Chromium ChromiumFeature chromium://flags')

    def test_pack_preserves_binary_resources_and_ids(self):
        original = {101: b'Chromium', 102: b'\x1f\x8b\xff', 103: b'\xff', 104: b'The Chromium Authors', 105: b'\x1f\x8b\xfe'}
        result = {}
        fake = SimpleNamespace(UTF8=1, UTF16=2,
            ReadDataPack=lambda _: SimpleNamespace(encoding=1, resources=original),
            WriteDataPack=lambda resources, _, encoding: result.update(resources))
        with tempfile.TemporaryDirectory() as directory:
            info = Path(directory) / 'locale.pak.info'
            info.write_text('IDS_PRODUCT_NAME,101,strings.grd\nIDR_SYNONYMS,102,strings.grd\nIDS_COPYRIGHT,104,strings.grd\nIDS_TERMS_HTML,105,strings.grd\n')
            branding.rebrand_pak('unused', info, fake)
        self.assertEqual(result, {**original, 101: b'Bark'})

    def test_utf16_pack(self):
        result = {}
        fake = SimpleNamespace(UTF8=1, UTF16=2,
            ReadDataPack=lambda _: SimpleNamespace(encoding=2, resources={1: 'About Chromium'.encode('utf-16-le')}),
            WriteDataPack=lambda resources, _, encoding: result.update(resources))
        with tempfile.TemporaryDirectory() as directory:
            info = Path(directory) / 'locale.pak.info'
            info.write_text('IDS_ABOUT,1,strings.grd\n')
            branding.rebrand_pak('unused', info, fake)
        self.assertEqual(result[1].decode('utf-16-le'), 'About Bark')
