set -e
env -u LEAN_ACCEL_TRACE_FILE LEAN_ACCELERATOR=cpu ./acceleratorNativeProduct.lean.out > "$TMP_DIR/cpu.out"
cmp acceleratorNativeProduct.lean.out.expected "$TMP_DIR/cpu.out"
if [[ "$(uname -s)" == Darwin ]] && ! rg -q "^USE_METAL_ACCELERATOR:BOOL=OFF$" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  python3 - "$LEAN_ACCEL_TRACE_FILE" <<'PY'
import json, pathlib, sys
entries = [json.loads(s) for s in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert sum(e.get('operation') == 'native_map' and e['count'] == 107
           and e['backend'] == 'metal' and e['result_valid'] for e in entries) == 5
cached = [e for e in entries if e['uniform_pack_cache_hit']]
assert cached and all(e['uniform_device_cache_hit'] for e in cached)
assert all(e['uniform_bytes'] > e['input_bytes'] for e in cached)
PY
fi
