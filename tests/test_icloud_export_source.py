"""Static regression checks for the Settings-only iCloud export action."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI = (ROOT / 'btphonosinkprefs' / 'BTPSLogViewController.m').read_text()

class ICloudExportTests(unittest.TestCase):
    def test_export_is_in_settings_not_daemon(self):
        self.assertIn('UIDocumentPickerViewController', UI)
        self.assertIn('initForExportingURLs:@[fileURL] asCopy:YES', UI)
        self.assertIn('self.navigationItem.rightBarButtonItems', UI)

    def test_button_is_visible_and_interactive(self):
        self.assertIn('Save Log to iCloud Drive', UI)
        self.assertIn('action:@selector(exportToFiles)', UI)
        self.assertIn('[self.view addSubview:exportButton]', UI)
        self.assertIn('[_textView.bottomAnchor constraintEqualToAnchor:exportButton.topAnchor', UI)

    def test_full_report_is_used(self):
        self.assertIn('[[BTPSLogReader shared] fullText]', UI)
        self.assertIn('log writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding', UI)
        self.assertIn('@"BTPhonoSink-%@-%@.txt"', UI)

    def test_user_selects_location(self):
        self.assertIn('picker.delegate = self;', UI)
        self.assertIn('didPickDocumentsAtURLs:', UI)
        self.assertIn('documentPickerWasCancelled:', UI)
        self.assertNotIn('URLForUbiquityContainerIdentifier', UI)

    def test_cancel_and_completion_clean_temporary_file(self):
        self.assertEqual(UI.count('[self cleanupPendingExport];'), 3)
        self.assertIn('removeItemAtURL:_pendingExportURL', UI)

if __name__ == '__main__':
    unittest.main()
