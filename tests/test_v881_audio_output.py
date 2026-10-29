"""Run the production PCM callback with a fake AudioQueue; routing needs iOS."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "btpsaudiohelper/BTPSV88Stream.m"


class V881AudioOutput(unittest.TestCase):
    def test_render_silence_stop_race_and_pcm_levels(self):
        source = SOURCE.read_text()
        # Compile the actual C-compatible callback and level meter, not a copy.
        render = source.split("#define PCM_CAPACITY", 1)[1].split("static void stop_output", 1)[0]
        levels = source.split("typedef struct { uint32_t samples,nonzero,peak; } PCMLevels;", 1)[1].split("static void report_progress", 1)[0]
        harness = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
typedef int32_t OSStatus;
typedef void *AudioQueueRef;
typedef struct { void *mAudioData; uint32_t mAudioDataByteSize; } AudioQueueBuffer;
typedef AudioQueueBuffer *AudioQueueBufferRef;
static OSStatus AudioQueueEnqueueBuffer(AudioQueueRef,AudioQueueBufferRef,unsigned,const void *);
'''
        harness += "#define PCM_CAPACITY" + render
        harness += "typedef struct { uint32_t samples,nonzero,peak; } PCMLevels;" + levels
        harness += r'''
static unsigned enqueues;
static OSStatus enqueue_error;
static int stop_on_enqueue;
static OSStatus AudioQueueEnqueueBuffer(AudioQueueRef queue,AudioQueueBufferRef b,
                                      unsigned packets,const void *descriptions) {
    assert(b->mAudioDataByteSize==AUDIO_FRAMES*4u);
    assert(packets==0 && descriptions==NULL);
    enqueues++;
    if(stop_on_enqueue) __atomic_store_n(&((Output *)queue)->stopping,1,__ATOMIC_RELEASE);
    return enqueue_error;
}
static void init_output(Output *o) {
    memset(o,0,sizeof *o);
    assert(pthread_mutex_init(&o->lock,NULL)==0);
    enqueues=0;enqueue_error=0;stop_on_enqueue=0;
}
int main(void) {
    Output o;int16_t data[AUDIO_FRAMES*2];
    AudioQueueBuffer buffer={data,0};
    const int16_t expected[6]={INT16_MIN,0,123,-123,0,INT16_MAX};

    /* Stop suppresses both enqueue and PCM consumption. Then resume with a
     * wraparound read and a short buffer, preserving the exact PCM samples. */
    init_output(&o);o.stopping=1;o.read=PCM_CAPACITY-1;o.count=3;
    for(unsigned i=0;i<3;i++) {
        unsigned slot=(o.read+i)%PCM_CAPACITY;
        o.pcm[slot*2]=expected[i*2];o.pcm[slot*2+1]=expected[i*2+1];
    }
    for(unsigned i=0;i<AUDIO_FRAMES*2;i++) data[i]=42;
    render(&o,&o,&buffer);
    assert(enqueues==0 && o.count==3 && o.render_callbacks==0 && data[0]==42);
    o.stopping=0;render(&o,&o,&buffer);
    assert(enqueues==1 && o.count==0 && o.read==2);
    assert(o.render_tick==3);
    assert(memcmp(data,expected,sizeof expected)==0);
    for(unsigned i=6;i<AUDIO_FRAMES*2;i++) assert(data[i]==0);
    assert(o.render_callbacks==1 && o.submitted_frames==3 && o.submitted_nonzero==4);
    assert(o.silence_frames==AUDIO_FRAMES-3 && o.error==0);
    pthread_mutex_destroy(&o.lock);

    /* A busy decoder lock must produce silence without waiting or consuming. */
    init_output(&o);o.count=2;o.pcm[0]=999;
    assert(pthread_mutex_lock(&o.lock)==0);
    render(&o,&o,&buffer);
    assert(pthread_mutex_unlock(&o.lock)==0);
    assert(enqueues==1 && o.count==2 && o.read==0);
    assert(o.submitted_frames==0 && o.submitted_nonzero==0 && o.silence_frames==AUDIO_FRAMES);
    assert(o.render_tick==0);
    for(unsigned i=0;i<AUDIO_FRAMES*2;i++) assert(data[i]==0);
    pthread_mutex_destroy(&o.lock);

    /* A live enqueue error is reported; an error caused by an overlapping stop
     * is not carried into the next stream. Failed enqueue is not counted. */
    init_output(&o);enqueue_error=-66632;
    render(&o,&o,&buffer);
    assert(enqueues==1 && o.error==-66632 && o.silence_frames==0);
    assert(o.render_tick==0);
    pthread_mutex_destroy(&o.lock);
    init_output(&o);enqueue_error=-66632;stop_on_enqueue=1;
    render(&o,&o,&buffer);
    assert(enqueues==1 && o.stopping==1 && o.error==0 && o.silence_frames==0);
    assert(o.render_tick==0);
    render(&o,&o,&buffer);assert(enqueues==1);
    pthread_mutex_destroy(&o.lock);

    PCMLevels level={0};
    measure_pcm(&level,expected,3);
    assert(level.samples==6 && level.nonzero==4 && level.peak==32768);
    const int16_t zero[4]={0};measure_pcm(&level,zero,2);
    assert(level.samples==10 && level.nonzero==4 && level.peak==32768);
    level=(PCMLevels){0};measure_pcm(&level,zero,2);
    assert(level.samples==4 && level.nonzero==0 && level.peak==0);
    puts("v8.8.1 PCM render: wrap, underflow, busy lock, stop race and levels passed");
    return 0;
}
'''
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread"]
        env = dict(os.environ)
        if os.environ.get("BTPS_SANITIZE"):
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            env["ASAN_OPTIONS"] = "detect_leaks=0"
            env["UBSAN_OPTIONS"] = "halt_on_error=1"
        with tempfile.TemporaryDirectory() as td:
            c = pathlib.Path(td) / "render.c"
            exe = pathlib.Path(td) / "render"
            c.write_text(harness)
            built = subprocess.run([cc, *flags, str(c), "-o", str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            print(ran.stdout, end="")

    def test_speaker_route_and_teardown_guards(self):
        source = SOURCE.read_text()
        configure = source.split("static int configure_speaker(", 1)[1].split("static int start_output(", 1)[0]
        self.assertIn("AVAudioSessionCategoryPlayAndRecord", configure)
        self.assertIn("AVAudioSessionCategoryOptionDefaultToSpeaker", configure)
        self.assertIn("overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker", configure)
        for option in ("AllowBluetooth", "AllowBluetoothA2DP", "AllowAirPlay"):
            self.assertNotIn("AVAudioSessionCategoryOption" + option, source)
        start = source.split("static int start_output(", 1)[1].split("} PCMLevels;", 1)[0]
        self.assertLess(start.index("configure_speaker(rate,s)"), start.index("AudioQueueNewOutput("))
        self.assertLess(start.index("!speaker_selected(session)"), start.index("AudioQueueStart("))
        stop = source.split("static void stop_output(", 1)[1].split("static int speaker_selected(", 1)[0]
        self.assertLess(stop.index("&o->stopping,1"), stop.index("AudioQueueStop("))
        self.assertLess(stop.index("AudioQueueDispose("), stop.index("&o->error,0"))


if __name__ == "__main__":
    unittest.main()
