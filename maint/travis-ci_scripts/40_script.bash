#!/bin/bash

source maint/travis-ci_scripts/common.bash
if [[ -n "$SHORT_CIRCUIT_SMOKE" ]] ; then return ; fi

run_harness_tests() {
  local -x HARNESS_TIMER=1
  local -x HARNESS_OPTIONS=c:j$NUMTHREADS
  make test 2> >(tee "$TEST_STDERR_LOG")
}

TEST_T0=$SECONDS
if [[ "$CLEANTEST" = "true" ]] ; then
  echo_err "$(tstamp) Running tests with plain \`make test\`"
  run_or_err "Prepare blib" "make pure_all"
  run_harness_tests
else
  PROVECMD="prove --timer -lrswj$NUMTHREADS t xt"

  # FIXME - temporary, until Package::Stash is fixed
  if perl -M5.010 -e 1 &>/dev/null ; then
    PROVECMD="$PROVECMD -T"
  fi

  echo_err "$(tstamp) running tests with \`$PROVECMD\`"
  $PROVECMD 2> >(tee "$TEST_STDERR_LOG")
fi
TEST_T1=$SECONDS

if [[ -z "$DBICTRACE" ]] && [[ -z "$POISON_ENV" ]] && [[ -s "$TEST_STDERR_LOG" ]] ; then
  STDERR_LOG_SIZE=$(wc -l < "$TEST_STDERR_LOG")

  echo
  echo "Test run produced $STDERR_LOG_SIZE lines of output on STDERR:"
  echo "============================================================="
  cat "$TEST_STDERR_LOG"
  echo "============================================================="
  echo "End of test run STDERR output ($STDERR_LOG_SIZE lines)"
  echo

  if [[ -n "$INSTALLDEPS_SKIPPED_TESTLIST" ]] ; then
    echo "The following non-essential tests were skipped during deps installation"
    echo "============================================================="
    echo "$INSTALLDEPS_SKIPPED_TESTLIST"
    echo "============================================================="
    echo
  fi

  echo "Full dep install log at $(/usr/bin/nopaste -q -s Shadowcat -d DepInstall <<< "$INSTALLDEPS_OUT")"
  echo
fi

echo "$(tstamp) Testing took a total of $(( $TEST_T1 - $TEST_T0 ))s"