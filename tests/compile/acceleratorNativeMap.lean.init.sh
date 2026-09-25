TMP_DIR="$(mktemp -d)"
export TMP_DIR
export LEAN_NUM_THREADS="$(getconf _NPROCESSORS_ONLN)"
export LEAN_ACCELERATOR=metal
export LEAN_ACCELERATOR_MIN_ITEMS=1
export LEAN_ACCEL_TRACE_FILE="$TMP_DIR/native-map-trace.jsonl"
