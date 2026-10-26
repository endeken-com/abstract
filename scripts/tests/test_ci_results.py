"""Failure propagation for the required CI/release gate."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-test-results.py"
spec = importlib.util.spec_from_file_location("ci_results", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def results(event="pull_request", changed="true"):
    jobs = {name: {"result": "success"} for name in ("core-tests", "apple-transport", "macos-build")}
    jobs["mobile-changes"] = {
        "result": "success" if event == "pull_request" else "skipped",
        "outputs": {"changed": changed} if event == "pull_request" else {},
    }
    jobs["ios-check"] = {"result": "success" if event == "pull_request" and changed == "true" else "skipped"}
    return jobs


class TestCheckResults(unittest.TestCase):
    def test_success_for_mobile_pr_desktop_pr_and_release_branch_push(self):
        for event, changed in [("pull_request", "true"), ("pull_request", "false"), ("push", "")]:
            with self.subTest(event=event, changed=changed):
                gate.check_results(results(event, changed), event)

    def test_every_required_job_blocks_on_failure_cancellation_skip_or_missing_result(self):
        for event, changed in [("pull_request", "true"), ("pull_request", "false"), ("push", "")]:
            passing = results(event, changed)
            for name, job in passing.items():
                if job["result"] != "success":
                    continue
                for state in ("failure", "cancelled", "skipped", None):
                    with self.subTest(event=event, changed=changed, job=name, state=state):
                        jobs = copy.deepcopy(passing)
                        if state is None:
                            jobs.pop(name)
                        else:
                            jobs[name]["result"] = state
                        with self.assertRaises(ValueError):
                            gate.check_results(jobs, event)

    def test_failed_or_cancelled_optional_jobs_are_not_accepted_as_skips(self):
        for event in ("push", "pull_request"):
            passing = results(event, "false")
            for name, job in passing.items():
                if job["result"] != "skipped":
                    continue
                for state in ("failure", "cancelled", None):
                    with self.subTest(event=event, job=name, state=state):
                        jobs = copy.deepcopy(passing)
                        if state is None:
                            jobs.pop(name)
                        else:
                            jobs[name]["result"] = state
                        with self.assertRaisesRegex(ValueError, name):
                            gate.check_results(jobs, event)

    def test_missing_or_invalid_change_detection_never_skips_ios(self):
        for changed in (None, "", "TRUE", "unknown", True, False):
            with self.subTest(changed=changed):
                jobs = results(changed=changed)
                with self.assertRaisesRegex(ValueError, "mobile-changes"):
                    gate.check_results(jobs, "pull_request")

    def test_missing_change_outputs_fail_closed(self):
        jobs = results()
        jobs["mobile-changes"].pop("outputs")
        with self.assertRaisesRegex(ValueError, "mobile-changes"):
            gate.check_results(jobs, "pull_request")

    def test_unknown_workflow_event_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "event"):
            gate.check_results(results(), "workflow_dispatch")

    def test_command_exits_nonzero_for_failed_check_or_bad_input(self):
        failed = results("push")
        failed["macos-build"]["result"] = "failure"
        for data, success in [(json.dumps(results("push")), True), (json.dumps(failed), False), ("not json", False)]:
            with self.subTest(data=data):
                command = subprocess.run(
                    [sys.executable, str(SCRIPT)], capture_output=True, text=True,
                    env={**os.environ, "JOB_RESULTS": data, "EVENT_NAME": "push"},
                )
                self.assertEqual(command.returncode == 0, success, command.stderr)
                if not success:
                    self.assertIn("::error::", command.stderr)


if __name__ == "__main__":
    unittest.main()
