# The map size is the native conformance-test size. The repeat count matches the
# saved Nightstream replay's block count; this is a map benchmark, not that replay.
if [[ -n ${TEST_BENCH-} ]]; then
  TEST_ARGS=(65536 13680 chain)
else
  TEST_ARGS=(65536 1 chain)
fi
