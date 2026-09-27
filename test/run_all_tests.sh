#!/usr/bin/env bash
# Path:     test/run_all_tests.sh
# Project:  blast-radius-reproductions
# Revision: 1
# Updated:  2026-09-26
# Purpose:  The single test entry point for this repository. CI runs exactly
#           this command, and so can you, from any directory:
#
#               bash test/run_all_tests.sh;
#
#           Exits 0 only when every suite below passed. Each suite reports
#           how many tests it executed, and a suite that executed none fails
#           the run, here and in CI alike. When TESTS_EXECUTED_FILE is set, as
#           CI sets it, each suite also appends "<label><TAB><count>" to that
#           file. Scratch output goes to one temporary directory, removed on
#           exit.
#
# Suites:
#           The reproduction script, which asserts its own checks.
set -euo pipefail;

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)";
cd "${project_root}";
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/revisualized_tests.XXXXXX")";
trap 'rm -rf -- "${work_directory}"' EXIT;

fail() {
  echo "FAIL: ${1}" >&2;
  exit 1;
};

# Refuses a count of zero or a count that is not a number. A suite that ran
# nothing has not passed.
record_tests_executed() {
  local label="${1}";
  local count="${2}";
  if ! [[ "${count}" =~ ^[0-9]+$ ]] || [ "${count}" -eq 0 ]; then
    fail "suite '${label}' reported '${count}' tests executed";
  fi;
  echo "  executed: ${label}: ${count}";
  if [ -n "${TESTS_EXECUTED_FILE:-}" ]; then
    printf '%s\t%s\n' "${label}" "${count}" >> "${TESTS_EXECUTED_FILE}";
  fi;
};

# The reproduction script runs under set -e and prints its verdict last.
# Section 7 needs root and setpriv; without them it is skipped, and the
# count below says so by being 6 rather than 7.
run_reproductions() {
  local log_file="${work_directory}/reproductions.log";
  local sections_passed=6;
  echo "== reproductions: bash blast_radius_reproductions.sh";
  bash blast_radius_reproductions.sh 2>&1 | tee "${log_file}";
  grep -q '^sections 1-6: PASS$' "${log_file}" || fail "sections 1-6 did not report PASS";
  grep -q '^DEMONSTRATIONS: PASS' "${log_file}" || fail "the script did not report DEMONSTRATIONS: PASS";
  if grep -q '^section 7: *PASS$' "${log_file}"; then
    sections_passed=7;
  fi;
  record_tests_executed "reproduction sections passed" "${sections_passed}";
};

run_reproductions;

echo "All suites passed.";
