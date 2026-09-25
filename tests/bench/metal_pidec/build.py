import json, os, shlex, subprocess, sys, time
from pathlib import Path
if len(sys.argv)!=4:
    raise SystemExit('usage: build.py NIGHTSTREAM_FPRIME TOOLCHAIN OUTPUT')
p=Path(sys.argv[1]).resolve();t=Path(sys.argv[2]).resolve();r=Path(sys.argv[3]).resolve()
src=Path(__file__).resolve().parent
cc=subprocess.check_output(['xcrun','--find','clang'],text=True).strip()
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
r.mkdir(parents=True,exist_ok=True)
# Keep validate.sh's nested timeout in the outer timeout process group.
bounded=r/'bounded-tools';bounded.mkdir(exist_ok=True)
wrapper=bounded/'timeout'
wrapper.write_text('#!/bin/sh\nexec /opt/homebrew/bin/timeout --foreground "$@"\n')
wrapper.chmod(0o755)
e=os.environ.copy()
e['PATH']=str(bounded)+':'+e['PATH']
e['LEAN_PATH']=':'.join(str(q) for q in [p/'.lake/build/lib/lean', *sorted((p/'.lake/packages').glob('*/.lake/build/lib/lean'))])
e['LEAN_ACCELERATOR']='cpu'
e.pop('LEAN_ACCEL_TRACE_FILE',None)
e['LEAN_CC']=cc
outdir=r
outdir.mkdir(exist_ok=True)
commands=[]
def run(name,args):
    args=['/opt/homebrew/bin/timeout','--signal=KILL','300','bash','scripts/validate.sh','lean-executable',*map(str,args)]
    start=time.perf_counter()
    with (outdir/(name+'.log')).open('w') as log:
        q=subprocess.run(args,cwd=p,env=e,stdout=log,stderr=subprocess.STDOUT)
    commands.append(dict(name=name,args=args,exit=q.returncode,seconds=time.perf_counter()-start))
    (outdir/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    if q.returncode:
        print((outdir/(name+'.log')).read_text()[-6000:],flush=True)
        raise SystemExit(q.returncode)
    print(name,commands[-1]['seconds'],flush=True)
replacements={}
module='NightstreamFPrime/Export/PiDECCommitmentReplayMain'
base_setup=json.loads((p/('.lake/build/ir/'+module+'.setup.json')).read_text())
for name in ['Batch','Replay','BatchTest']:
 setup=dict(base_setup);setup['name']=name;setup['isModule']=False
 setup['importArts']=dict(base_setup['importArts'])
 if name!='Batch':
  setup['importArts']['Batch']=[str(outdir/('Batch'+suffix)) for suffix in ['.olean','.ir','.olean.server','.olean.private'] if (outdir/('Batch'+suffix)).exists()]
 setup_path=outdir/(name+'.setup.json');setup_path.write_text(json.dumps(setup))
 c=outdir/(name+'.c');obj=outdir/(name+'.o')
 run(name+'-lean',[t/'bin/lean',src/(name+'.lean'),'--root',src,'--setup',setup_path,'-o',outdir/(name+'.olean'),'-c',c])
 run(name+'-c',[cc,'-c','-O3','-DNDEBUG','-DLEAN_EXPORTING','-fvisibility=hidden','-fdata-sections','-ffunction-sections','-I',t/'include','-isysroot',sdk,c,'-o',obj])
replacements[str(p/('.lake/build/ir/'+module+'.c.o.export'))]=str(outdir/'Replay.o')
for stem in ['metal_batch','lean_bridge']:
 extension='.mm' if stem=='metal_batch' else '.cpp'
 args=[cc,'-c','-O3','-std=c++17','-DNDEBUG','-I',t/'include','-isysroot',sdk,src/(stem+extension),'-o',outdir/(stem+'.o')]
 if extension=='.mm':args.insert(1,'-fobjc-arc')
 run(stem,args)
args=shlex.split((p/'.lake/build/bin/replayPiDECCommitment.rsp').read_text())
# Reuse checked project objects and replace only the replay driver.
# Keep the baseline runtime; use the active Xcode SDK and system libraries.
if not any(str(t/'lib/lean') in a for a in args):
    raise SystemExit('Use the same toolchain that built the stock replay')
args=[replacements.get(a,a) for a in args]
clean=[]; i=0
while i<len(args):
    if args[i]=='--sysroot':
        clean.extend(['-isysroot',sdk]);i+=2
    elif args[i]=='-fuse-ld=lld':i+=1
    else:clean.append(args[i]);i+=1
clean.extend([str(outdir/'Batch.o'),str(outdir/'metal_batch.o'),str(outdir/'lean_bridge.o'),'-L/opt/homebrew/lib','-lc++','-framework','Foundation','-framework','Metal'])
response=outdir/'link.rsp'
response.write_text('\n'.join(json.dumps(a) for a in clean)+'\n')
run('link',[cc,'@'+str(response),'-o',outdir/'replayPiDECCommitment'])

test_args=[str(outdir/'BatchTest.o') if arg==str(outdir/'Replay.o') else arg for arg in clean]
test_response=outdir/'test-link.rsp'
test_response.write_text('\n'.join(json.dumps(a) for a in test_args)+'\n')
run('test-link',[cc,'@'+str(test_response),'-o',outdir/'batchTest'])
run('kernel-test-build',[cc,'-x','objective-c++','-O3','-std=c++17','-fobjc-arc','-isysroot',sdk,src/'test_batch.cpp',src/'metal_batch.mm','-framework','Foundation','-framework','Metal','-lc++','-o',outdir/'kernelTest'])
run('key-test-build',[cc,'-x','objective-c++','-O3','-std=c++17','-fobjc-arc','-isysroot',sdk,src/'test_keys.cpp',src/'metal_batch.mm','-framework','Foundation','-framework','Metal','-lc++','-o',outdir/'keyTest'])
