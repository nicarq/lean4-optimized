set -e
env -u LEAN_ACCEL_TRACE_FILE LEAN_ACCELERATOR=cpu ./acceleratorNativeChain.lean.out > "$TMP_DIR/cpu.out"
cmp acceleratorNativeChain.lean.out.expected "$TMP_DIR/cpu.out"
if [[ "$(uname -s)" == Darwin ]] && ! rg -q "^USE_METAL_ACCELERATOR:BOOL=OFF$" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  python3 - "$LEAN_ACCEL_TRACE_FILE" <<'PYCODE'
import json, pathlib, sys
entries = [json.loads(s) for s in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(entries) == 4, entries
assert all(e['operation'] == 'native_chain' and e['stages'] == 2 for e in entries)
assert sum(e['result_valid'] for e in entries) == 3
assert all(e['synchronizations'] == 1 and e['host_intermediate_bytes'] == 0 for e in entries)
PYCODE
fi
