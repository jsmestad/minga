"""Behavioral fixtures for native acceptance accounting, not native receipts."""

import copy
import importlib.machinery
import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/test_macos_unit"
LOADER = importlib.machinery.SourceFileLoader("macos_unit", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
native = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(native)


def summary(passed=8, failed=0):
    return {
        "totalTestCount": passed + failed,
        "passedTests": passed,
        "failedTests": failed,
        "result": "Passed" if failed == 0 else "Failed",
    }


def case(identifier, children=None):
    node = {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Passed"}
    if children is not None:
        node["children"] = children
    return node


def tree(suite, children):
    return {"testNodes": [{
        "nodeType": "Test Suite", "nodeIdentifier": suite,
        "result": "Passed", "children": children,
    }]}


def replay_tree(named=True):
    arguments = [case(name) for name in sorted(native.REPLAY_CASES)] if named else None
    return tree(native.REPLAY, [
        case("corpusIsEnumerated()"), case("replay(_:)", arguments),
    ])


def log(pid=4102):
    return f"[Focus application picker_open_close] startup pid={pid} active=false\n"


class MacOSUnitResultsTest(unittest.TestCase):
    def test_named_replay_cases_and_flattened_xcode_counts_are_accepted(self):
        for named in (True, False):
            errors, pids = native.validate_action("focus-replay", summary(), replay_tree(named), log(), 0)
            self.assertEqual(errors, [])
            self.assertEqual(pids, [4102])

    def test_missing_named_case_cannot_hide_behind_a_passing_summary(self):
        tests = replay_tree()
        tests["testNodes"][0]["children"][1]["children"].pop()
        errors, _ = native.validate_action("focus-replay", summary(), tests, log(), 0)
        self.assertTrue(any("all seven cases" in error for error in errors))

    def test_flattened_replay_requires_seven_passes_plus_enumeration(self):
        errors, _ = native.validate_action("focus-replay", summary(7), replay_tree(False), log(), 0)
        self.assertTrue(any("all seven cases" in error for error in errors))
        tests = replay_tree(False)
        tests["testNodes"][0]["children"].pop(0)
        errors, _ = native.validate_action("focus-replay", summary(), tests, log(), 0)
        self.assertTrue(any("enumeration" in error for error in errors))

    def test_failed_suite_fails_even_with_a_passing_summary_and_children(self):
        tests = replay_tree()
        tests["testNodes"][0]["result"] = "Failed"
        errors, _ = native.validate_action("focus-replay", summary(), tests, log(), 0)
        self.assertTrue(any("Failed test or suite" in error for error in errors))

    def test_ordinary_result_must_not_contain_either_focus_suite(self):
        for suite in (native.POLICY, native.REPLAY):
            tests = tree(suite, [case("example()")])
            errors, _ = native.validate_action("ordinary", summary(1), tests, "", 0)
            self.assertIn("Ordinary action included an isolated focus suite", errors)
        errors, _ = native.validate_action("ordinary", summary(1), tree("RenderingTests", [case("caret()")]), "", 0)
        self.assertEqual(errors, [])

    def test_policy_requires_the_actual_nested_modal_case(self):
        tests = tree(native.POLICY, [case("lifecycleAppliesOnlyDecodedOwner()")])
        errors, _ = native.validate_action("focus-policy", summary(1), tests, log(4101), 0)
        self.assertEqual(errors, [])
        tests["testNodes"][0]["children"] = [case("someOtherCase()")]
        errors, _ = native.validate_action("focus-policy", summary(1), tests, log(4101), 0)
        self.assertIn("Required nested-modal lifecycle case did not pass", errors)

    def test_unrelated_executions_violate_focus_process_ownership(self):
        tests = replay_tree()
        tests["testNodes"].extend(tree("OtherWindowTests", [case("ordersWindow()")])["testNodes"])
        errors, _ = native.validate_action("focus-replay", summary(9), tests, log(), 0)
        self.assertTrue(any("unrelated test" in error for error in errors))

    def test_pid_receipt_must_identify_exactly_one_actual_runner(self):
        for output in ("", log(4102) + log(4103)):
            errors, _ = native.validate_action("focus-replay", summary(), replay_tree(), output, 0)
            self.assertTrue(any("test-runner PID" in error for error in errors))

    def test_command_success_cannot_replace_missing_empty_or_invalid_results(self):
        for counts, tests in (
            (None, None),
            (summary(0), {"testNodes": []}),
            ({**summary(), "passedTests": None}, replay_tree(False)),
            (summary(), {"testNodes": []}),
        ):
            errors, _ = native.validate_action("focus-replay", counts, tests, log(), 0)
            self.assertTrue(errors)
        errors, _ = native.validate_action("focus-replay", summary(), replay_tree(), log(), 65)
        self.assertIn("xcodebuild exited 65", errors)

    def test_manifest_preserves_actual_results_and_aggregates_only_actual_counts(self):
        actions = [
            {"name": "ordinary", "summary": summary(100), "tests": tree("RenderingTests", [case("caret()")]), "success": True},
            {"name": "focus-policy", "summary": summary(12), "tests": tree(native.POLICY, [case("lifecycleAppliesOnlyDecodedOwner()")]), "success": True},
            {"name": "focus-replay", "summary": summary(), "tests": replay_tree(), "success": True},
        ]
        original = copy.deepcopy(actions)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = native.save_results(output, actions, time.monotonic())
            self.assertTrue(result["success"])
            self.assertEqual(result["total_passed_tests"], 120)
            self.assertEqual(result["total_failed_tests"], 0)
            self.assertEqual(json.loads((output / "results.json").read_text())["actions"], original)
            actions[2]["summary"] = None
            actions[2]["success"] = False
            result = native.save_results(output, actions, time.monotonic())
            self.assertFalse(result["success"])
            self.assertEqual(result["total_passed_tests"], 112)
            self.assertFalse(native.save_results(output, actions[:2], time.monotonic())["success"])


if __name__ == "__main__":
    unittest.main()
