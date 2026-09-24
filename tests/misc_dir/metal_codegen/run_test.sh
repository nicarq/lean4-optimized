# Bound generated source before compiling it, then check both execution paths.
lean -Dcompiler.metal=true -c "$TMP_DIR/metal.c" Main.lean
test "$(wc -c < "$TMP_DIR/metal.c")" -lt 200000 || fail "Metal source grew beyond the bounded fallback"
leanc -O2 -o "$TMP_DIR/metal.out" "$TMP_DIR/metal.c"
LEAN_METAL=0 "$TMP_DIR/metal.out" > "$TMP_DIR/cpu.txt"
LEAN_METAL=1 "$TMP_DIR/metal.out" > "$TMP_DIR/gpu.txt"
diff -u "$TMP_DIR/cpu.txt" "$TMP_DIR/gpu.txt"
