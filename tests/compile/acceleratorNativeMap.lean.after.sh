set -e
env -u LEAN_ACCEL_TRACE_FILE LEAN_ACCELERATOR=cpu ./acceleratorNativeMap.lean.out > "$TMP_DIR/native-map-cpu.out"
cmp acceleratorNativeMap.lean.out.expected "$TMP_DIR/native-map-cpu.out"
env LEAN_ACCELERATOR=auto LEAN_ACCELERATOR_MIN_ITEMS=18446744073709551615 \
  LEAN_ACCEL_TRACE_FILE="$TMP_DIR/native-map-threshold.jsonl" \
  ./acceleratorNativeMap.lean.out > "$TMP_DIR/native-map-threshold.out"
cmp acceleratorNativeMap.lean.out.expected "$TMP_DIR/native-map-threshold.out"
test ! -e "$TMP_DIR/native-map-threshold.jsonl"
if [[ "$(uname -s)" == Darwin ]] && ! rg -q "^USE_METAL_ACCELERATOR:BOOL=OFF$" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  python3 - "$LEAN_ACCEL_TRACE_FILE" <<'PY'
import json, pathlib, sys
entries = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
maps = [entry for entry in entries if entry.get("operation") == "native_map"]
assert len(maps) >= 4, maps
assert sum(entry["backend"] == "metal" and entry["result_valid"] for entry in maps) >= 4
assert any(entry["backend"] == "cpu" and not entry["result_valid"] for entry in maps)
PY
fi
