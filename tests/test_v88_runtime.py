"""Portable runtime regressions; real iOS playback is a separate device test."""
import os, pathlib, shutil, subprocess, tempfile, unittest
P=pathlib.Path(__file__).resolve().parents[1]
class V88Runtime(unittest.TestCase):
 def test_shared_ring_control_and_continuous_decode(self):
  cc=shutil.which('cc')
  self.assertIsNotNone(cc)
  with tempfile.TemporaryDirectory() as td:
   exe=str(pathlib.Path(td)/'v88')
   src=['tests/v88_runtime.c','BTPSV88Shared.c','BTPSV88Control.c',
        'btpsaudiohelper/BTPSV88Decode.c','btpsaudiohelper/BTPSV76Decode.c',
        'btpsaudiohelper/vendor_sbc/sbc.c','btpsaudiohelper/vendor_sbc/bits.c']
   flags=['-std=gnu11','-O2','-Wall','-Wextra','-Werror','-pthread','-I'+str(P),'-I'+str(P/'btpsaudiohelper/vendor_sbc')]
   if os.environ.get('BTPS_SANITIZE'): flags+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
   objects=[]
   for i,file in enumerate(src):
    obj=str(pathlib.Path(td)/('%d.o'%i));objects.append(obj)
    # Upstream fixed-point SBC deliberately shifts signed negatives. Check
    # upstream memory with ASan; use UBSan on our new queue/control/adapter.
    opts=[f.replace('-fsanitize=address,undefined','-fsanitize=address') for f in flags if f!='-Werror'] if '/vendor_sbc/' in file else flags
    r=subprocess.run([cc,*opts,'-c',str(P/file),'-o',obj],capture_output=True,text=True)
    self.assertEqual(r.returncode,0,r.stderr)
   r=subprocess.run([cc,*flags,*objects,'-o',exe],capture_output=True,text=True)
   self.assertEqual(r.returncode,0,r.stderr)
   env=dict(os.environ)
   if os.environ.get('BTPS_SANITIZE'):
    env['ASAN_OPTIONS']='detect_leaks=0' # LSan cannot inspect /proc under this runner
    env['UBSAN_OPTIONS']='halt_on_error=1'
   r=subprocess.run([exe,str(P/'tests/fixtures/v75_actual_captured_258_frames.sbc')],capture_output=True,text=True,timeout=30,env=env)
   self.assertEqual(r.returncode,0,r.stdout+r.stderr)
   print(r.stdout,end='')
 def test_receive_thread_has_no_io_allocation_or_tls(self):
  s=(P/'BTPSV88Daemon.c').read_text().split('void BTPSV88Forward(',1)[1].split('static void drain_logs',1)[0]
  for term in ('BTPSLog','malloc(', 'calloc(', 'send(', 'recv(', 'write(', 'pthread_', 'dispatch_', 'btps_peek', '__thread'):
   self.assertNotIn(term,s)
  queue=(P/'BTPSV88Shared.c').read_text()
  for term in ('malloc(', 'pthread_', 'usleep(', 'write(', 'syscall', 'while('): self.assertNotIn(term,queue)
 def test_activation_is_one_shot_and_callback_is_table_swap(self):
  s=(P/'Tweak.xm').read_text()
  self.assertIn('if(g_v82_armed && uuid_ok) g_v88_ready=BTPSV88Prepare();',s)
  block=s.split('static int btps_v88_install_callback(',1)[1].split('/* v8.3 one-shot:',1)[0]
  self.assertNotIn('MSHookFunction',block)
  self.assertIn('ptrauth_sign_unauthenticated(raw,ptrauth_key_function_pointer,0)',block)
  self.assertIn('g_v88_callbacks[22]',block)
 def test_tx_packet_captured_before_native_ownership_transfer(self):
  s=(P/'Tweak.xm').read_text().split('static uint64_t btps_v82_transmit_signal(',1)[1].split('static void btps_v82_install_tx(',1)[0]
  self.assertLess(s.index('int control_ok='),s.index('uint64_t ret = g_v82_tx_orig'))
  self.assertIn('if(ret==0u && control_ok)',s)
 def test_launchd_plist(self):
  import plistlib
  p=plistlib.loads((P/'layout/Library/LaunchDaemons/com.parv.btphonosink.audio.plist').read_bytes())
  self.assertEqual(p['UserName'],'mobile')
  self.assertEqual(p['Sockets']['Stream']['SockNodeName'],'127.0.0.1')
  self.assertEqual(p['ProgramArguments'],['/var/jb/usr/bin/BTPSAudioHelper','--stream-service'])
  self.assertNotIn('KeepAlive',p)
if __name__=='__main__':unittest.main()
