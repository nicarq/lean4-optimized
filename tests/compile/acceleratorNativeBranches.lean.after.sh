set -e
env -u LEAN_ACCEL_TRACE_FILE LEAN_ACCELERATOR=cpu ./acceleratorNativeBranches.lean.out > "$TMP_DIR/cpu.out"
cmp acceleratorNativeBranches.lean.out.expected "$TMP_DIR/cpu.out"
if [[ "$(uname -s)" == Darwin ]] && ! rg -q "^USE_METAL_ACCELERATOR:BOOL=OFF$" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  python3 - "$LEAN_ACCEL_TRACE_FILE" <<'PY'
import json, pathlib, sys
entries = [json.loads(s) for s in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert any(e['count'] == 1 and e['backend'] == 'metal' and e['result_valid'] for e in entries)
assert any(e['count'] == 2 and e['backend'] == 'cpu' and not e['result_valid'] for e in entries)
PY
fi
