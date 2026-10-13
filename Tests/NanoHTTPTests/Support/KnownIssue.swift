//
//  KnownIssue.swift
//  NanoHTTPTests
//
//  Test support: how this suite tracks defects that have been *found* but not yet *fixed*.
//
//  A test wrapped in `expectKnownIssue` asserts the CORRECT behavior. While the defect exists,
//  the assertion fails, XCTest records that as an *expected* failure, and the suite stays green.
//  The moment the defect is fixed the assertion passes, XCTest reports "expected failure did not
//  occur" and the test goes red. That is the cue to delete the `expectKnownIssue` wrapper, so a
//  fix can never be forgotten and the test then guards against regressions.
//
//  The `id` ties the test to the finding in the assessment plan (S1, H4, ...).
//
//  Two escape hatches for defects that cannot be expressed as an expected failure:
//    * `requireCrashTests` – the defect crashes the whole test process (trap, abort). The test is
//      skipped unless `NANOHTTP_CRASH_TESTS=1` is set; run it deliberately to confirm the crash
//      and again after the fix. Phase 1 removes the gate for every test whose bug got fixed.
//    * `strict: false` – for races, where a given run may or may not exhibit the failure.
//

import XCTest

func expectKnownIssue(_ id: String,
                      _ summary: String,
                      strict: Bool = true,
                      _ body: () throws -> Void) rethrows {
  let options = XCTExpectedFailure.Options()
  options.isStrict = strict
  try XCTExpectFailure("\(id): \(summary)", options: options) {
    try body()
  }
}

func requireCrashTests(_ id: String, _ summary: String) throws {
  try XCTSkipUnless(ProcessInfo.processInfo.environment["NANOHTTP_CRASH_TESTS"] == "1",
                    "\(id): \(summary) — crashes the test process until fixed. " +
                    "Run with NANOHTTP_CRASH_TESTS=1 to execute.")
}
