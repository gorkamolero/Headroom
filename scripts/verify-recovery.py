import argparse, ctypes, json, os, pathlib, selectors, signal, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description="Live display recovery test: makes brief 1% table adjustments, then verifies restoration.")
parser.add_argument('--live', action='store_true', help='Run the actual display experiment')
parser.add_argument('--guardian', type=pathlib.Path, default=ROOT / '.build/release/DisplayGuardian')
parser.add_argument('--evidence', type=pathlib.Path, default=ROOT / 'Evidence/LiveRun')
args = parser.parse_args()
if not args.live:
    parser.error('Pass --live to run tests that briefly change your main display.')
BINARY = args.guardian.resolve()
if not BINARY.is_file() or not os.access(BINARY, os.X_OK):
    parser.error('Guardian executable missing; build it first or provide --guardian PATH.')
STATE = ROOT / '.build/live-recovery-state'
EVIDENCE = args.evidence.resolve()
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayGammaTableCapacity.argtypes = [ctypes.c_uint32]
cg.CGDisplayGammaTableCapacity.restype = ctypes.c_uint32
cg.CGGetDisplayTransferByTable.argtypes = [ctypes.c_uint32,ctypes.c_uint32,ctypes.POINTER(ctypes.c_float),ctypes.POINTER(ctypes.c_float),ctypes.POINTER(ctypes.c_float),ctypes.POINTER(ctypes.c_uint32)]
cg.CGGetDisplayTransferByTable.restype = ctypes.c_int
DISPLAY = cg.CGMainDisplayID()
def table():
    cap = cg.CGDisplayGammaTableCapacity(DISPLAY)
    assert 0 < cap < 65537
    arrays = [(ctypes.c_float * cap)() for _ in range(3)]
    count = ctypes.c_uint32()
    assert cg.CGGetDisplayTransferByTable(DISPLAY, cap, *arrays, ctypes.byref(count)) == 0
    return [list(a)[:count.value] for a in arrays]
def diff(a,b):
    assert all(len(x)==len(y) for x,y in zip(a,b))
    return max(abs(x-y) for ac,bc in zip(a,b) for x,y in zip(ac,bc))
def start():
    p = subprocess.Popen([str(BINARY),'--journal-dir',str(STATE)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    buffers[p.pid] = bytearray()
    row = receive(p)
    assert row['event']=='ready' and row['ok'], row
    return p
buffers = {}
def send(p, **request):
    p.stdin.write((json.dumps(request)+'\n').encode()); p.stdin.flush()
def receive(p, deadline=8):
    end = time.monotonic()+deadline
    buffer = buffers[p.pid]
    with selectors.DefaultSelector() as sel:
        sel.register(p.stdout,selectors.EVENT_READ)
        while time.monotonic()<end:
            if b'\n' in buffer:
                raw, remainder = buffer.split(b'\n',1); buffer[:] = remainder
                return json.loads(raw)
            if sel.select(max(0,end-time.monotonic())):
                data = os.read(p.stdout.fileno(),4096)
                if not data: raise RuntimeError('Helper exited: '+p.stderr.read().decode())
                buffer.extend(data)
    raise TimeoutError('No guardian reply')
def next_event(p, event, deadline=8):
    end = time.monotonic()+deadline
    while time.monotonic()<end:
        row = receive(p,max(.1,end-time.monotonic()))
        if row['event']==event:return row
    raise TimeoutError(event)
baseline = table()
EVIDENCE.mkdir(parents=True, exist_ok=True)
(EVIDENCE/'live-baseline.json').write_text(json.dumps({'displayID':DISPLAY,'tables':baseline}))
rows=[]
try:
    for case in ['stop','parentEOF','leaseExpiry','deadline','SIGTERM','SIGKILL_then_recover']:
        p = start()
        send(p,command='begin',displayID=DISPLAY,factor=1.01,duration=2 if case=='deadline' else 20)
        began = next_event(p,'began')
        assert began['ok'], began
        active = table()
        start_time = time.monotonic()
        if case=='stop':send(p,command='stop')
        elif case=='parentEOF':p.stdin.close()
        elif case=='SIGTERM':p.terminate()
        elif case=='SIGKILL_then_recover':
            p.kill();p.wait(timeout=5)
            recovery = subprocess.run([str(BINARY),'--journal-dir',str(STATE),'--recover'],capture_output=True,text=True,timeout=8)
            assert recovery.returncode==0,recovery.stdout+recovery.stderr
            ended = {'event':'explicitRecovery','output':recovery.stdout}
        if case!='SIGKILL_then_recover':
            ended = next_event(p,'ended',deadline=8)
            assert ended['ok'],ended
        restoration=diff(baseline,table())
        assert restoration<=0.0005,restoration
        if p.poll() is None:
            if not p.stdin.closed:
                send(p,command='quit');p.stdin.close()
            p.wait(timeout=5)
        row={'case':case,'began':began,'ended':ended,'recoverySeconds':time.monotonic()-start_time,'activeDifferenceFromOriginal':diff(baseline,active),'restorationMaxDifference':restoration,'remainingJournals':len(list(STATE.glob('*.json')))}
        assert row['remainingJournals']==0,row
        rows.append(row); print(json.dumps(row),flush=True)
finally:
    if 'p' in locals() and p.poll() is None:
        if not p.stdin.closed:p.stdin.close()
        try:p.wait(timeout=8)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    rescue=subprocess.run([str(BINARY),'--journal-dir',str(STATE),'--recover'],capture_output=True,text=True,timeout=8)
    final_diff=diff(baseline,table())
    result={'testDate':time.strftime('%Y-%m-%d'),'displayID':DISPLAY,'factor':1.01,'cases':rows,'finalRestorationMaxDifference':final_diff,'finalRecoveryExit':rescue.returncode,'photometry':'not measured'}
    (EVIDENCE/'guardian-live.json').write_text(json.dumps(result,indent=2))
    assert final_diff<=0.0005,(final_diff,rescue.stdout)
