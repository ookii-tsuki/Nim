# Shared by the run_*.sh gates: runs a gate's tests side by side and prints their
# output in the order the tests were given, so a log reads the same however the
# runs interleave. Sourced, not run.
#
# A gate that uses it handles `--one <file>` itself, early in the script: it runs
# that single test, prints what the serial loop used to, and exits non-zero if the
# test failed. `ns_par_each` then launches `<gate> --one <file>` for every file.
#
#   NS_JOBS=<n>    how many tests run at once (default: the number of cores)
#   NS_CACHE=<dir> where each test keeps its own Nim cache (default: ~/.cache/ns-gates)
#
# Tests share names (many are `main.ns`) and Nim keys its default cache by that
# name, so run side by side they would overwrite each other's build; every test
# therefore gets a cache directory of its own (`ns_nimcache`), which also lets a
# later run reuse the C it compiled before.

ns_jobs() {
  printf '%s' "${NS_JOBS:-$(nproc 2>/dev/null || echo 2)}"
}

ns_nimcache() {
  ## ns_nimcache ROOT FILE SUFFIX: this test's Nim cache. ROOT is hashed in, so two
  ## checkouts (the repository and a gate worktree) never share one while both run;
  ## SUFFIX tells apart the builds of one test that differ (reversed, C++).
  _rel="${2#$1/}"
  _key="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  _name="$(printf '%s' "${_rel%.ns}" | tr '/' '_')"
  printf '%s/%s/%s%s' "${NS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ns-gates}" "$_key" "$_name" "$3"
}

ns_flags() {
  ## ns_flags FILE: the compiler options a test asks for in `<name>.flags` (a
  ## target, say `--os:any`, or `--compile:$DIR/x.c` with `$DIR` the test's
  ## directory), added to its every build; none without one.
  [ -f "${1%.ns}.flags" ] && sed "s#\$DIR#$(dirname "$1")#g" "${1%.ns}.flags"
  return 0
}

ns_par_each() {
  ## ns_par_each OUTDIR FILE...: runs `<this gate> --one FILE` for each FILE, up to
  ## ns_jobs at once, then prints their output in order. Returns non-zero if any
  ## of them failed.
  _dir="$1"; shift
  rm -rf "$_dir"; mkdir -p "$_dir"
  ## Counted here: a counter bumped inside the pipeline below would live in its
  ## subshell, and the results would never be read back.
  _n=$#
  _i=0
  for _f in "$@"; do
    _i=$((_i + 1))
    printf '%s|%s\n' "$_i" "$_f"
  done | tr '\n' '\000' | xargs -0 -P "$(ns_jobs)" -I{} sh -c '
    idx="${3%%|*}"; f="${3#*|}"
    sh "$1" --one "$f" > "$2/$idx.out" 2>&1 < /dev/null
    echo "$?" > "$2/$idx.rc"
  ' _ "$0" "$_dir" {}
  _failed=0
  _k=1
  while [ "$_k" -le "$_n" ]; do
    cat "$_dir/$_k.out"
    [ "$(cat "$_dir/$_k.rc" 2>/dev/null)" = "0" ] || _failed=1
    _k=$((_k + 1))
  done
  return $_failed
}
