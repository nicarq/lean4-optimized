# Defaults must preserve CPU-only builds; explicit unsupported opt-ins still fail.
for compiler in AppleClang Clang; do
  cmake -DTEST_APPLE=TRUE -DTEST_COMPILER_ID="$compiler" -DEXPECTED=ON -P check.cmake
  cmake -DTEST_APPLE=TRUE -DTEST_COMPILER_ID="$compiler" -DUSE_METAL=OFF -DEXPECTED=OFF -P check.cmake
done
cmake -DTEST_APPLE=TRUE -DTEST_COMPILER_ID=GNU -DEXPECTED=OFF -P check.cmake
for compiler in GNU Clang; do
  cmake -DTEST_APPLE=FALSE -DTEST_COMPILER_ID="$compiler" -DEXPECTED=OFF -P check.cmake
done
for platform in TRUE FALSE; do
  capture_fail cmake -DTEST_APPLE="$platform" -DTEST_COMPILER_ID=GNU -DUSE_METAL=ON -P check.cmake
  check_out_contains "Metal requires an Apple platform and a Clang C++ compiler"
done
capture_fail cmake -DTEST_APPLE=FALSE -DTEST_COMPILER_ID=Clang -DUSE_METAL=ON -P check.cmake
check_out_contains "Metal requires an Apple platform and a Clang C++ compiler"
