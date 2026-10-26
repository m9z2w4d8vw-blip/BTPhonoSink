"""Non-mutating design gates for the new opt-in daemon sender and Settings UI."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class DaemonProbeTests(unittest.TestCase):
    def test_the_daemon_probe_is_a_separate_file_not_a_bluetooth_callback(self):
        tweak=(ROOT/'Tweak.xm').read_text()
        self.assertIn('BTPSDaemonProbeStart();',tweak)
        self.assertIn('"v7.5-sbc-rtp-ipc-probe"',tweak)
        self.assertNotIn('socket(',tweak)
        self.assertNotIn('send(',tweak)
        self.assertNotIn('btps_ipc_encode_daemon_v74',tweak)
        self.assertNotIn('BTPS_AVDTP_TSEP_SNK',tweak)
    def test_socket_and_audio_only_in_notification_worker(self):
        probe=(ROOT/'BTPSDaemonProbe.c').read_text()
        for term in ['notify_register_dispatch','dispatch_queue_create','DISPATCH_QUEUE_SERIAL',
                     'attempt_test(t)', 'CFPreferencesCopyValue','INADDR_LOOPBACK','O_NONBLOCK',
                     'SO_SNDTIMEO', 'SO_RCVTIMEO','SO_NOSIGPIPE','BTPS_IPC_PCM_BYTES',
                     'btps_ipc_encode_daemon_v74', 'g_v74_last_uuid','g_v74_last_time',
                     'BTPSSetStatus("diag.v74_ipc"']:
            self.assertIn(term,probe)
        self.assertNotIn('AVAudioPlayer',probe)
        self.assertNotIn('MSHookFunction',probe)
        self.assertNotIn('OI_SDPDB_AddServiceRecord',probe)
        self.assertNotIn('AVDTP_RegisterMultipoint(',probe)
    def test_request_explicit_and_correlated(self):
        ui=(ROOT/'btphonosinkprefs/BTPSLogViewController.m').read_text()
        shared=(ROOT/'BTPSShared.h').read_text()
        for term in ['Send PCM from bluetoothd (v7.4)','promptDaemonIPCTest','notify_post(BTPS_NOTIFY_DAEMON_PROBE)',
                     'CFPreferencesSynchronize','NSUUID UUID','--daemon','six digits']:
            self.assertIn(term,ui)
        self.assertIn('BTPS_NOTIFY_DAEMON_PROBE',shared)
        self.assertIn('BTPS_KEY_DAEMON_PROBE',shared)
    def test_helper_preserves_old_mode_and_enforces_new_version(self):
        helper=(ROOT/'btpsaudiohelper/main.m').read_text()
        self.assertIn('daemon_mode=argc>=2',helper)
        self.assertIn('BTPS_IPC_V74_HEADER_SIZE',helper)
        self.assertIn('btps_ipc_validate_daemon_v74',helper)
        self.assertIn('btps_ipc_validate(header,token,pcm',helper)
        self.assertIn('daemon_mode?880:660',helper)
        self.assertIn('INADDR_LOOPBACK',helper)
    def test_prefs_and_logger_export_v74_status(self):
        log=(ROOT/'btphonosinkprefs/BTPSLogReader.m').read_text()
        self.assertIn('V7.4 BLUETOOTHD-TO-HELPER REQUEST',log)
        self.assertIn('diag.v74_ipc',log)
        self.assertIn('BTPSDaemonIPCRequestLastResult',log)
    def test_theos_build_includes_protocol_and_worker(self):
        make=(ROOT/'Makefile').read_text()
        self.assertIn('BTPSIPCProtocol.c BTPSDaemonProbe.c BTPSV74Tone.c',make)
        self.assertIn('-fblocks',make)
        self.assertIn('btpsaudiohelper',make)
if __name__=='__main__':unittest.main()
