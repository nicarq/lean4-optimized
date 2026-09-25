export TMP_DIR="$(mktemp -d)"
export LEAN_ACCELERATOR=metal
export LEAN_ACCELERATOR_MIN_ITEMS=1
export LEAN_ACCEL_TRACE_FILE="$TMP_DIR/native-product.jsonl"
