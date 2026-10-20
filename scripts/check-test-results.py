"""Keep the release-required `test` check strict after splitting CI into jobs."""

import json
import os
import sys


def check_results(jobs, event):
    expected = {name: "success" for name in ("core-tests", "apple-transport", "macos-build")}
    if event == "pull_request":
        expected["mobile-changes"] = "success"
        changed = jobs.get("mobile-changes", {}).get("outputs", {}).get("changed")
        if changed not in ("true", "false"):
            raise ValueError("mobile-changes did not report whether iOS checks are required")
        expected["ios-check"] = "success" if changed == "true" else "skipped"
    elif event == "push":
        expected.update({"mobile-changes": "skipped", "ios-check": "skipped"})
    else:
        raise ValueError(f"Unexpected test workflow event: {event}")

    errors = []
    for name, wanted in expected.items():
        actual = jobs.get(name, {}).get("result", "missing")
        if actual != wanted:
            errors.append(f"{name}: expected {wanted}, got {actual}")
    if errors:
        raise ValueError("; ".join(errors))


if __name__ == "__main__":
    try:
        check_results(json.loads(os.environ["JOB_RESULTS"]), os.environ["EVENT_NAME"])
    except (KeyError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
    print("All required tests and builds passed.")
