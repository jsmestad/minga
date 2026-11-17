"""Behavioral fixtures for native acceptance accounting, not native receipts."""

import copy
import importlib.machinery
import importlib.util
import json
import plistlib
import runpy
import shutil
import signal
import sys
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
GEOMETRY_FIXTURE_PATH = SCRIPT.parents[1] / "test/fixtures/native_approval_geometry_observer.py"
GEOMETRY_FIXTURE = runpy.run_path(str(GEOMETRY_FIXTURE_PATH))["write_fixture"]


def geometry_fixture(directory, width=220):
    observer, host = directory / "observer", directory / "host"
    context = (directory, "case-a", width, 4103, observer, host, 4104)
    return GEOMETRY_FIXTURE(*context), context


def geometry_process_fixture(directory):
    observer, host = directory / "observer", directory / "MingaTestHost"
    for destination in (observer, host):
        shutil.copyfile(GEOMETRY_FIXTURE_PATH, destination)
        destination.chmod(0o755)
    return observer, host


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
    return {"__xctestrun_metadata__": {"FormatVersion": 1}, "MingaTests": {
        "BlueprintName": "MingaTests",
        "TestHostPath": "__TESTROOT__/Debug/MingaTestHost.app",
        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/MingaTests.xctest",
        "EnvironmentVariables": {"MINGA_TEST_PRODUCTION_APP_PATH": "__TESTROOT__/Debug/Minga.app"},
        "OnlyTestIdentifiers": [native.POLICY],
        "SkipTestIdentifiers": [native.REPLAY],
        "DependentProductPaths": ["__PLATFORMS__/MacOSX.platform"],
    }}


def log(pid=4102):
    return f"[Focus application picker_open_close] startup pid={pid} active=false\n"


class MacOSUnitResultsTest(unittest.TestCase):
    def test_named_replay_cases_are_independent_of_logical_function_counts(self):
        errors, pids = native.validate_action("focus-replay", summary(2), replay_tree(), log(), 0)
        self.assertEqual(errors, [])
        self.assertEqual(pids, [4102])

    def test_geometry_accepts_external_names_frames_and_native_scale_images_at_all_widths(self):
        with tempfile.TemporaryDirectory() as directory:
            for width in native.GEOMETRY_WIDTHS:
                case = Path(directory) / str(width)
                case.mkdir()
                value, context = geometry_fixture(case, width)
                for button in value["buttons"]:
                    button["title_attribute"] = "AXDescription"
                for initial_frontmost in (False, True):
                    with self.subTest(width=width, initial_frontmost=initial_frontmost):
                        value["foreground"] = {"initial_frontmost": initial_frontmost, "request_count": 0 if initial_frontmost else 1, "observed_frontmost": True}
                        errors, captured = native.validate_geometry_observation(value, *context)
                        self.assertEqual(errors, [])
                        self.assertTrue(captured)

    def test_geometry_rejects_clipped_overlapping_disabled_or_unhittable_controls(self):
        mutations = [
            (("workspace", "width"), 221),
            (("workspace", "width"), 1 << 8192),
            (("buttons", 0, "frame", "width"), 80),
            (("buttons", 0, "frame", "x"), float("nan")),
            (("buttons", 1, "frame", "y"), 50),
            (("buttons", 0, "enabled"), False),
            (("buttons", 0, "press_capable"), False),
            (("buttons", 0, "center_hits_exact_button"), False),
            (("buttons", 0, "title"), "An unrelated button"),
            (("buttons", 0, "title"), []),
        ]
        with tempfile.TemporaryDirectory() as directory:
            original, context = geometry_fixture(Path(directory))
            for path, replacement in mutations:
                with self.subTest(path=path):
                    value = copy.deepcopy(original)
                    subject = value
                    for key in path[:-1]:
                        subject = subject[key]
                    subject[path[-1]] = replacement
                    errors, captured = native.validate_geometry_observation(value, *context)
                    self.assertTrue(any(error.startswith("assertion:") for error in errors))
                    self.assertTrue(captured)
            original["buttons"].pop()
            errors, _ = native.validate_geometry_observation(original, *context)
            self.assertTrue(any("all four" in error for error in errors))

    def test_geometry_rejects_cross_run_identity_and_corrupt_captures(self):
        mutations = [
            (("run_id",), "previous-case"),
            (("observer_pid",), 4102),
            (("foreground",), None),
            (("foreground", "initial_frontmost"), "false"),
            (("foreground", "initial_frontmost"), True),
            (("foreground", "request_count"), 0),
            (("foreground", "request_count"), 2),
            (("foreground", "request_count"), True),
            (("foreground", "observed_frontmost"), False),
            (("host", "window_id"), 100),
            (("capture", "sha256"), "0" * 64),
            (("capture", "decoded_pixel_width"), 221),
            (("capture", "scale"), 1 << 8192),
            (("capture", "scale"), 1e308),
            (("capture", "ax_window_bounds", "x"), -1),
        ]
        with tempfile.TemporaryDirectory() as directory:
            original, context = geometry_fixture(Path(directory))
            for path, replacement in mutations:
                with self.subTest(path=path):
                    value = copy.deepcopy(original)
                    subject = value
                    for key in path[:-1]:
                        subject = subject[key]
                    subject[path[-1]] = replacement
                    errors, _ = native.validate_geometry_observation(value, *context)
                    self.assertTrue(any(error.startswith("infrastructure:") for error in errors))
            image = Path(directory) / "window.png"
            image.write_bytes(b"corrupt")
            errors, captured = native.validate_geometry_observation(original, *context)
            self.assertTrue(any("PNG" in error for error in errors))
            self.assertFalse(captured)
            image.unlink()
            errors, captured = native.validate_geometry_observation(original, *context)
            self.assertTrue(any("PNG" in error for error in errors))
            self.assertFalse(captured)

    def test_containment_overflow_is_retained_as_invalid_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            value, context = geometry_fixture(Path(directory))
            for key in ("point_bounds", "ax_window_bounds"):
                value["capture"][key].update({"x": 1 << 1023, "width": 1 << 1023})
            errors, captured = native.validate_geometry_observation(value, *context)
            self.assertTrue(any("Invalid native capture bounds" in error for error in errors))
            self.assertFalse(captured)

    def test_positive_host_failure_is_reported_even_when_already_reaped(self):
        with native.subprocess.Popen([sys.executable, "-c", "raise SystemExit(1)"], stdin=native.subprocess.DEVNULL, stdout=native.subprocess.DEVNULL, stderr=native.subprocess.STDOUT, start_new_session=True) as process:
            self.assertEqual(process.wait(timeout=10), 1)
            errors = []
            native.stop_geometry_process(process, "host", errors, grace=0.1)
            self.assertTrue(any("host exited unexpectedly" in error for error in errors))

    def test_lifecycle_evidence_cannot_claim_stale_identity_or_unobserved_cleanup(self):
        expected = {
            "run_id": "case-a", "width": 220, "supervisor_pid": 4100,
            "host": {"executable": "/host", "pid": 4104, "pgid": 4104, "status": "terminated_reaped", "return_code": 0},
            "observer": {"executable": "/observer", "pid": 4103, "pgid": 4103, "status": "terminated_reaped", "return_code": 0},
        }
        launch = copy.deepcopy(expected)
        launch["schema"] = "minga-approval-geometry-launch-v2"
        for role in ("host", "observer"):
            launch[role].update({"status": "launched", "return_code": None})
        cleanup = {"schema": "minga-approval-geometry-cleanup-v1", **copy.deepcopy(expected), "descriptors_closed": True, "errors": []}
        self.assertEqual(native.validate_geometry_lifecycle(launch, cleanup, expected), [])
        for path, replacement in (
            (("run_id",), "stale"), (("supervisor_pid",), 1),
            (("host", "pid"), 4105), (("host", "status"), "not_launched"),
            (("host", "return_code"), None), (("descriptors_closed",), False),
            (("errors",), ["host could not be reaped"]),
        ):
            with self.subTest(path=path):
                forged = copy.deepcopy(cleanup)
                subject = forged
                for key in path[:-1]:
                    subject = subject[key]
                subject[path[-1]] = replacement
                self.assertTrue(native.validate_geometry_lifecycle(launch, forged, expected))

    def test_early_observer_exit_still_kills_and_reaps_an_uncooperative_host(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            observer, host = geometry_process_fixture(base)
            (base / "early-observer-exit").touch()
            (base / "ignore-host-shutdown").touch()
            receipt = {"run_id": "early-exit", "width": 220, "validation_errors": []}
            native.run_geometry_case(base / "case", receipt, observer, host, lambda: None, timeout=10, grace=0.1)
            self.assertFalse(receipt["success"])
            self.assertTrue(receipt["cleanup_verified"])
            self.assertEqual(receipt["cleanup"]["observer"]["return_code"], 7)
            self.assertEqual(receipt["cleanup"]["host"]["return_code"], -signal.SIGKILL)

    def test_cancellation_between_launches_reaps_the_host_without_starting_an_observer(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            observer, host = geometry_process_fixture(base)
            receipt = {"run_id": "between-launches", "width": 220, "validation_errors": []}
            def cancelled():
                return signal.SIGINT if receipt.get("launch", {}).get("host", {}).get("pid") is not None else None
            native.run_geometry_case(base / "case", receipt, observer, host, cancelled, timeout=10, grace=0.1)
            self.assertFalse(receipt["success"])
            self.assertTrue(receipt["cleanup_verified"])
            self.assertEqual(receipt["cleanup"]["host"]["status"], "terminated_reaped")
            self.assertIs(type(receipt["cleanup"]["host"]["return_code"]), int)
            self.assertEqual(receipt["cleanup"]["observer"]["status"], "not_launched")
            self.assertIsNone(receipt["cleanup"]["observer"]["pid"])

    def test_cancellation_escalates_and_reaps_an_observer_that_ignores_term(self):
        for host_ready in (True, False):
            with self.subTest(host_ready=host_ready), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                observer, host = geometry_process_fixture(base)
                (base / "ignore-observer-term").touch()
                if not host_ready:
                    (base / "withhold-host-ready").touch()
                receipt = {"run_id": "observer-escalation", "width": 220, "validation_errors": []}
                cancelled = lambda: signal.SIGINT if (base / "observer-armed").exists() else None
                native.run_geometry_case(base / "case", receipt, observer, host, cancelled, timeout=10, grace=0.1)
                self.assertFalse(receipt["success"])
                self.assertTrue(receipt["cleanup_verified"])
                self.assertEqual(receipt["cleanup"]["observer"]["return_code"], -signal.SIGKILL, receipt)
                self.assertEqual(receipt["cleanup"]["host"]["status"], "terminated_reaped")

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

    def test_symlinked_product_paths_identify_the_same_runner_and_replay_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "Products"
            products.mkdir()
            alias = root / "Alias"
            alias.symlink_to(products, target_is_directory=True)
            host_relative = Path("Debug/MingaTestHost.app/Contents/MacOS/MingaTestHost")
            host = products / host_relative
            host.parent.mkdir(parents=True)
            host.touch()
            for hosted in (False, True):
                relative = Path("Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest" if hosted else "Debug/MingaTests.xctest")
                bundle = products / relative
                bundle.mkdir(parents=True)
                settings = [{"target": "MingaTests", "buildSettings": {
                    "TEST_HOST": str(alias / host_relative) if hosted else "",
                    "BUNDLE_LOADER": str(alias / host_relative) if hosted else "",
                    "TARGET_BUILD_DIR": str((alias / relative).parent),
                    "FULL_PRODUCT_NAME": bundle.name,
                }}]
                runtime = f"[MingaTestHost] didFinishLaunching pid=4101 bundle=com.minga.test-host executable={alias / host_relative}\n{log(4101)}" if hosted else "xctest[4100:123] native runtime\n"
                self.assertEqual(native.validate_execution_identity(settings, runtime, products, hosted), [])
                wrong = copy.deepcopy(settings)
                wrong[0]["buildSettings"]["TARGET_BUILD_DIR"] = str(root / "Other" / relative.parent)
                self.assertTrue(native.validate_execution_identity(wrong, runtime, products, hosted))
                bundle.rmdir()

            plan = hosted_plan()
            target = plan["MingaTests"]
            target["TestHostPath"] = str(alias / "Debug/MingaTestHost.app")
            target["TestBundlePath"] = str(alias / "Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest")
            target["EnvironmentVariables"]["MINGA_TEST_PRODUCTION_APP_PATH"] = str(alias / "Debug/Minga.app")
            source = products / "MingaUnitTests_macosx.xctestrun"
            source.write_bytes(plistlib.dumps(plan))
            receipts = native.snapshot_plans(products, root / "receipts")
            selected, _ = native.select_hosted_plan({}, receipts, products, True)
            self.assertEqual(Path(selected), source)

    def test_only_a_current_successful_unique_hosted_plan_authorizes_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory) / "Products"
            products.mkdir()
            source = products / "MingaUnitTests_macosx.xctestrun"
            source.write_bytes(plistlib.dumps(hosted_plan()))
            before = native.snapshot_plans(products, Path(directory) / "before")
            current = hosted_plan()
            current["__xctestrun_metadata__"]["currentBuild"] = True
            source.write_bytes(plistlib.dumps(current))
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
        for plan in (
            {**hosted_plan(), "OtherTests": {}},
            {**hosted_plan(), "__xctestrun_metadata__": {"FormatVersion": 2}},
        ):
            with self.assertRaises(ValueError):
                native.validate_hosted_plan(plan, products)

    def test_relocated_focus_plans_preserve_launch_metadata_and_replace_only_target_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path("/original/Products")
            original = hosted_plan()
            original["__xctestrun_metadata__"]["SkipTestIdentifiers"] = ["unrelated metadata"]
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
                self.assertEqual(plan["__xctestrun_metadata__"], original["__xctestrun_metadata__"])
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
            {"name": "approval-geometry", "summary": None, "tests": None, "success": True, **{key: list(native.GEOMETRY_WIDTHS) for key in ("attempted_widths", "observed_widths", "captured_widths", "passed_widths")}},
        ]
        original = copy.deepcopy(actions)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = native.save_results(output, actions, time.monotonic())
            self.assertTrue(result["success"])
            self.assertEqual(result["total_passed_tests"], 114)
            self.assertEqual(result["total_failed_tests"], 0)
            self.assertEqual(json.loads((output / "results.json").read_text())["actions"], original)
            for key in ("attempted_widths", "observed_widths", "captured_widths", "passed_widths"):
                incomplete = copy.deepcopy(original)
                incomplete[3][key].pop()
                self.assertFalse(native.save_results(output, incomplete, time.monotonic())["success"])
            invented = copy.deepcopy(original)
            invented[3]["summary"] = summary(3)
            result = native.save_results(output, invented, time.monotonic())
            self.assertFalse(result["success"])
            self.assertEqual(result["total_passed_tests"], 114)
            actions[2]["summary"] = None
            actions[2]["success"] = False
            result = native.save_results(output, actions, time.monotonic())
            self.assertFalse(result["success"])
            self.assertEqual(result["total_passed_tests"], 112)
            self.assertFalse(native.save_results(output, actions[:2], time.monotonic())["success"])
            self.assertFalse(native.save_results(output, original[:3], time.monotonic())["success"])


if __name__ == "__main__":
    unittest.main()
