"""Behavioral fixtures for native acceptance accounting, not native receipts."""

import copy
import importlib.machinery
import importlib.util
import json
import plistlib
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/test_macos_unit"
LOADER = importlib.machinery.SourceFileLoader("macos_unit", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
native = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(native)


def summary(passed=2, failed=0):
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
    arguments = [
        {"nodeType": "Arguments", "name": name, "result": "Passed"}
        for name in sorted(native.REPLAY_CASES)
    ] if named else None
    return tree(native.REPLAY, [
        case("corpusIsEnumerated()"), case("replay(_:)", arguments),
    ])


def policy_tree():
    return tree(native.POLICY, [
        case(f"{native.POLICY}/{name}()") for name in sorted(native.POLICY_FUNCTIONS)
    ])


def hosted_plan():
    return {"TestConfigurations": [{"TestTargets": [{
        "BlueprintName": "MingaTests",
        "TestHostPath": "__TESTROOT__/Debug/MingaTestHost.app/Contents/MacOS/MingaTestHost",
        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/MingaTests.xctest",
        "EnvironmentVariables": {"MINGA_TEST_PRODUCTION_APP_PATH": "__TESTROOT__/Debug/Minga.app"},
        "OnlyTestIdentifiers": [native.POLICY],
        "SkipTestIdentifiers": [native.REPLAY],
        "DependentProductPaths": ["__PLATFORMS__/MacOSX.platform"],
    }]}]}


def log(pid=4102):
    return f"[Focus application picker_open_close] startup pid={pid} active=false\n"


class MacOSUnitResultsTest(unittest.TestCase):
    def test_named_replay_cases_are_independent_of_logical_function_counts(self):
        errors, pids = native.validate_action("focus-replay", summary(2), replay_tree(), log(), 0)
        self.assertEqual(errors, [])
        self.assertEqual(pids, [4102])

    def test_missing_named_case_cannot_hide_behind_a_passing_summary(self):
        tests = replay_tree()
        tests["testNodes"][0]["children"][1]["children"].pop()
        errors, _ = native.validate_action("focus-replay", summary(), tests, log(), 0)
        self.assertTrue(any("all seven cases" in error for error in errors))

    def test_named_receipts_must_be_passed_argument_nodes(self):
        for replacement in ({"nodeType": "Test Case"}, {"result": "Skipped"}):
            tests = replay_tree()
            argument = tests["testNodes"][0]["children"][1]["children"][0]
            argument.update(replacement)
            errors, _ = native.validate_action("focus-replay", summary(), tests, log(), 0)
            self.assertTrue(any("all seven cases" in error for error in errors))

    def test_flattened_counts_cannot_replace_named_argument_evidence(self):
        for passed in (2, 7, 8, 100):
            errors, _ = native.validate_action("focus-replay", summary(passed), replay_tree(False), log(), 0)
            self.assertTrue(any("all seven cases" in error for error in errors))
        tests = replay_tree()
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

    def test_policy_requires_every_own_function_not_passing_ancestors(self):
        tests = policy_tree()
        errors, _ = native.validate_action("focus-policy", summary(13), tests, log(4101), 0)
        self.assertEqual(errors, [])
        for replacement in (None, {"result": "Skipped"}, {"nodeType": "Test Suite"}):
            incomplete = copy.deepcopy(tests)
            node = incomplete["testNodes"][0]["children"].pop()
            if replacement is not None:
                node.update(replacement)
                incomplete["testNodes"][0]["children"].append(node)
            errors, _ = native.validate_action("focus-policy", summary(13), incomplete, log(4101), 0)
            self.assertTrue(any("all 13 own passed functions" in error for error in errors))
        tests["testNodes"][0]["children"].append(case(f"{native.POLICY}/unrelated()"))
        errors, _ = native.validate_action("focus-policy", summary(14), tests, log(4101), 0)
        self.assertTrue(any("unexpected" in error for error in errors))

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
        self.assertIn("Native action exited 65", errors)

    def test_bare_and_hosted_identities_require_settings_product_and_runtime_agreement(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            host = products / "Debug/MingaTestHost.app/Contents/MacOS/MingaTestHost"
            host.parent.mkdir(parents=True)
            host.touch()
            for hosted in (False, True):
                bundle = products / ("Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest" if hosted else "Debug/MingaTests.xctest")
                bundle.mkdir(parents=True)
                settings = [{"target": "MingaTests", "buildSettings": {
                    "TEST_HOST": str(host) if hosted else "", "BUNDLE_LOADER": str(host) if hosted else "",
                    "TARGET_BUILD_DIR": str(bundle.parent), "FULL_PRODUCT_NAME": bundle.name,
                }}]
                runtime = f"[MingaTestHost] didFinishLaunching pid=4101 bundle=com.minga.test-host executable={host}\n{log(4101)}" if hosted else "xctest[4100:123] native runtime\n"
                self.assertEqual(native.validate_execution_identity(settings, runtime, products, hosted), [])
                for wrong in ("", "xctest[4100:123]" if hosted else runtime + f"[MingaTestHost] didFinishLaunching pid=4101"):
                    self.assertTrue(native.validate_execution_identity(settings, wrong, products, hosted))
                for key, value in (("TEST_HOST", "" if hosted else str(host)), ("BUNDLE_LOADER", "wrong"), ("TARGET_BUILD_DIR", "/wrong")):
                    changed = copy.deepcopy(settings)
                    changed[0]["buildSettings"][key] = value
                    self.assertTrue(native.validate_execution_identity(changed, runtime, products, hosted))
                bundle.rmdir()
                self.assertTrue(native.validate_execution_identity(settings, runtime, products, hosted))

    def test_only_a_current_successful_unique_hosted_plan_authorizes_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory) / "Products"
            products.mkdir()
            source = products / "MingaUnitTests_macosx.xctestrun"
            source.write_bytes(plistlib.dumps(hosted_plan()))
            before = native.snapshot_plans(products, Path(directory) / "before")
            source.write_bytes(plistlib.dumps({**hosted_plan(), "currentBuild": True}))
            after = native.snapshot_plans(products, Path(directory) / "after")
            selected, _ = native.select_hosted_plan(before, after, products, True)
            self.assertEqual(selected, str(source))
            for prior, current, passed in ((after, after, True), ({}, {}, True), (before, after, False)):
                with self.assertRaises(ValueError):
                    native.select_hosted_plan(prior, current, products, passed)
            second = products / "MingaUnitTests_other.xctestrun"
            second.write_bytes(source.read_bytes())
            ambiguous = native.snapshot_plans(products, Path(directory) / "ambiguous")
            with self.assertRaisesRegex(ValueError, "got 2"):
                native.select_hosted_plan({}, ambiguous, products, True)

    def test_wrong_host_bundle_target_or_app_environment_cannot_select_a_plan(self):
        products = Path("/build/Products")
        for key, value in (
            ("TestHostPath", "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"),
            ("TestBundlePath", "__TESTROOT__/Debug/MingaTests.xctest"),
            ("BlueprintName", "UnrelatedTests"), ("EnvironmentVariables", {}),
            ("IsAppHostedTestBundle", False),
        ):
            plan = hosted_plan()
            native.plan_target(plan)[key] = value
            with self.assertRaises(ValueError):
                native.validate_hosted_plan(plan, products)

    def test_relocated_focus_plans_preserve_launch_metadata_and_replace_only_target_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path("/original/Products")
            original = hosted_plan()
            original["SkipTestIdentifiers"] = ["unrelated metadata"]
            policy_path = Path(directory) / "policy.xctestrun"
            policy = native.pin_focus_plan(original, products, policy_path, native.POLICY)
            replay_path = Path(directory) / "replay.xctestrun"
            native.pin_focus_plan(policy, products, replay_path, native.REPLAY)
            for path, suite in ((policy_path, native.POLICY), (replay_path, native.REPLAY)):
                plan = plistlib.loads(path.read_bytes())
                native.validate_hosted_plan(plan, products)
                target = native.plan_target(plan)
                self.assertEqual(target["OnlyTestIdentifiers"], [suite])
                self.assertNotIn("SkipTestIdentifiers", target)
                self.assertEqual(plan["SkipTestIdentifiers"], original["SkipTestIdentifiers"])
                self.assertTrue(target["TestHostPath"].startswith(str(products)))
                self.assertEqual(target["DependentProductPaths"], ["__PLATFORMS__/MacOSX.platform"])
                self.assertEqual(target["EnvironmentVariables"], {"MINGA_TEST_PRODUCTION_APP_PATH": str(products / "Debug/Minga.app")})
            self.assertEqual(native.plan_target(policy)["OnlyTestIdentifiers"], [native.POLICY])
            self.assertEqual(native.plan_target(original)["SkipTestIdentifiers"], [native.REPLAY])

    def test_probe_failures_retain_causes_instead_of_becoming_missing_target_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "settings.json"
            for code, text in ((65, ""), (0, "{invalid JSON"), (0, "[]")):
                def run_probe(*args, **kwargs):
                    kwargs["stdout"].write(text)
                    kwargs["stderr"].write("retained probe diagnostic\n")
                    return SimpleNamespace(returncode=code)
                with patch.object(native.subprocess, "run", side_effect=run_probe):
                    probe, settings = native.capture_build_settings([], [], output, directory)
                self.assertEqual(probe["exit_code"], code)
                self.assertEqual(Path(probe["stderr"]).read_text(), "retained probe diagnostic\n")
                if code or text != "[]":
                    self.assertIsNone(settings)
                    self.assertTrue(probe["error"])
                else:
                    self.assertIsNone(probe["error"])
                    self.assertIn("Missing unique MingaTests", native.validate_execution_identity(settings, "", Path(directory), False)[0])
            with patch.object(native.subprocess, "run", side_effect=FileNotFoundError("xcodebuild unavailable")):
                probe, settings = native.capture_build_settings([], [], output, directory)
            self.assertIsNone(settings)
            self.assertIsNone(probe["exit_code"])
            self.assertIn("Could not execute", probe["error"])

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
            self.assertEqual(result["total_passed_tests"], 114)
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
