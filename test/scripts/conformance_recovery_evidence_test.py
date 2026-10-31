"""Unit accounting fixtures, not real mutation receipts or native execution."""
import copy
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
LOADER = importlib.machinery.SourceFileLoader("recovery_evidence", str(ROOT / "scripts/check_conformance_recovery"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
evidence = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(evidence)


def native_result():
    identifier = "ConformanceTranscriptTests/runsTranscript(_:)"
    url = "test://com.apple.xcode/Minga/MingaTests/" + identifier
    messages = [
        "ConformanceTranscriptTests.swift:352: Expectation failed: matches: " + evidence.TARGET + " step 2: transaction_result",
        "ConformanceTranscriptTests.swift:361: Expectation failed: (dispatcher.lastCommittedGeneration → 3) == "
        '(UInt32(last["generation"] as? Int ?? 0) → 2): ' + evidence.GENERATION_ASSERTION,
        "ConformanceTranscriptTests.swift:171: Expectation failed: (outboundActions.last → .frameApplied(generation: 3, frameSequence: 21)) == "
        "(Self.expectedAction(step) → .frameApplied(generation: 2, frameSequence: 21)): " + evidence.TARGET + " step 3: frame_status",
    ]
    return {
        "exit_code": 65, "bundle_exists": True,
        # xcresult's summary retains only the first issue for this failed argument.
        "summary": {"passedTests": 1, "failedTests": 1, "testFailures": [{
            "failureText": "Expectation failed: matches: " + evidence.TARGET + " step 2: transaction_result",
            "testIdentifierString": identifier, "testIdentifierURL": url,
        }]},
        "tests": {"testNodes": [
            {"nodeType": "Test Case", "name": "corpus enumerates transcripts", "result": "Passed",
             "nodeIdentifier": "ConformanceTranscriptTests/corpusIsPopulated()"},
            {"nodeType": "Test Case", "name": "runsTranscript(_:)", "result": "Failed",
             "nodeIdentifier": identifier, "nodeIdentifierURL": url, "children": [
                 {"nodeType": "Arguments", "name": evidence.TARGET, "result": "Failed", "children": [
                     {"nodeType": "Failure Message", "name": message} for message in messages
                 ]},
             ]},
        ]},
    }


class RecoveryEvidenceTest(unittest.TestCase):
    def test_native_kill_requires_named_generation_assertion_not_only_nonzero(self):
        self.assertTrue(evidence.native_generation_failure(native_result()))
        for field, value in [("bundle_exists", False), ("summary", None), ("tests", None),
                             ("exit_code", 0), ("exit_code", None)]:
            with self.subTest(field=field, value=value):
                result = native_result()
                result[field] = value
                self.assertFalse(evidence.native_generation_failure(result))

    def test_native_kill_rejects_unrelated_failures_zero_tests_and_wrong_assertions(self):
        for change in ("unrelated-summary", "unrelated-tree", "zero", "wrong-test", "wrong-summary-owner",
                       "wrong-assertion", "marker-without-expression", "wrong-tree-owner", "missing-tree-issues", "skipped-sibling"):
            with self.subTest(change=change):
                result = native_result()
                argument = result["tests"]["testNodes"][1]["children"][0]
                if change == "unrelated-summary":
                    result["summary"]["testFailures"].append({"failureText": "native lifecycle focus failed"})
                elif change == "unrelated-tree":
                    argument["children"].append({"nodeType": "Failure Message", "name": "Expectation failed: pane_rects"})
                elif change == "zero":
                    result["summary"].update(passedTests=0, failedTests=0)
                elif change == "wrong-test":
                    argument["name"] = "a different case"
                elif change == "wrong-summary-owner":
                    result["summary"]["testFailures"][0]["testIdentifierString"] = "OtherTests/runsTranscript(_:)"
                elif change == "wrong-assertion":
                    argument["children"][1]["name"] = "Expectation failed: " + evidence.TARGET + " step 2: pane_rects"
                elif change == "marker-without-expression":
                    argument["children"][1]["name"] = "Expectation failed: " + evidence.GENERATION_ASSERTION
                elif change == "wrong-tree-owner":
                    result["tests"]["testNodes"][0]["children"] = [argument["children"].pop(1)]
                elif change == "skipped-sibling":
                    result["summary"]["skippedTests"] = 1
                    result["tests"]["testNodes"].append({
                        "nodeType": "Test Case", "nodeIdentifier": "ConformanceTranscriptTests/Pixels/runsPixelTranscript(_:)",
                        "name": "pixel transcript conforms", "result": "Skipped", "children": [{
                            "nodeType": "Failure Message", "name": "Test 'pixel transcript conforms' skipped: No test cases found.",
                        }],
                    })
                else:
                    argument["children"] = []
                self.assertFalse(evidence.native_generation_failure(result))

    def test_control_requires_the_named_passing_case_and_no_failures(self):
        result = native_result()
        result["exit_code"] = 0
        result["summary"] = {"passedTests": 2, "failedTests": 0}
        argument = result["tests"]["testNodes"][1]["children"][0]
        argument["result"] = "Passed"
        result["tests"]["testNodes"][1]["result"] = "Passed"
        argument["children"] = []
        self.assertTrue(evidence.native_control_passes(result))
        result["summary"]["passedTests"] = 0
        self.assertFalse(evidence.native_control_passes(result))
        result["summary"]["passedTests"] = 2
        argument["name"] = "unrelated passing test"
        self.assertFalse(evidence.native_control_passes(result))
        self.assertTrue(evidence.native_control_passes(result, named_case=None))
        result["tests"] = None
        self.assertFalse(evidence.native_control_passes(result, named_case=None))

    def test_pure_and_generation_failures_require_the_actual_policy_reason(self):
        text = ("test " + evidence.PURE_CASE + " (MingaEditor.Renderer.RecoveryDecisionTest)\n"
                "Assertion with == failed\nleft: %{generation: 3}\nright: %{generation: 2}\n"
                "5 tests, 2 failures\n")
        self.assertTrue(evidence.exunit_generation_failure({"exit_code": 2}, text))
        self.assertFalse(evidence.exunit_generation_failure({"exit_code": 0}, text))
        self.assertFalse(evidence.exunit_generation_failure({"exit_code": 2}, "Compilation error"))
        self.assertFalse(evidence.exunit_generation_failure({"exit_code": 2}, text.replace("generation: 3", "seq: 3")))
        drift = ("** (Mix) conformance corpus differs: test/conformance/corpus/recovery/"
                 + evidence.TARGET + ".json at steps[2].expect.last_committed.generation; run mix conformance.gen")
        self.assertTrue(evidence.corpus_generation_failure({"exit_code": 1}, drift))
        self.assertFalse(evidence.corpus_generation_failure({"exit_code": 1}, drift.replace("generation;", "frame_seq;")))
        self.assertFalse(evidence.corpus_generation_failure({"exit_code": 1}, "no tests or compiler failure"))

    def test_inverse_is_unique_and_does_not_change_other_policy(self):
        source = (ROOT / evidence.SOURCE).read_text()
        changed = evidence.inverse(source)
        self.assertEqual(changed.replace(evidence.NEW, evidence.OLD, 1), source)
        with self.assertRaises(RuntimeError):
            evidence.inverse(source + "\n" + evidence.OLD)
        with self.assertRaises(RuntimeError):
            evidence.inverse(source.replace(evidence.OLD, ""))

    def test_wire_overlay_keeps_every_baseline_expectation_and_status_step(self):
        path = ROOT / "test/conformance/corpus/recovery/retryable_base_sequence.json"
        baseline = json.loads(path.read_text())
        mutant = copy.deepcopy(baseline)
        mutant["steps"][2]["expect"]["last_committed"]["generation"] += 1
        # Both carriers below are actual committed encoder output; this test
        # checks field selection only and makes no claim about mutant behavior.
        for field in evidence.WIRE_FIELDS:
            mutant["steps"][2][field] = copy.deepcopy(baseline["steps"][0][field])
        replay = evidence.overlay_transcripts(baseline, mutant)
        self.assertEqual(replay["steps"][2]["expect"], baseline["steps"][2]["expect"])
        self.assertEqual(replay["steps"][3], baseline["steps"][3])
        for field in evidence.WIRE_FIELDS:
            self.assertEqual(replay["steps"][2][field], mutant["steps"][2][field])
        for step, original in zip(replay["steps"], baseline["steps"]):
            for key, value in original.items():
                if key not in evidence.WIRE_FIELDS or original["kind"] != "framed":
                    self.assertEqual(step[key], value)

    def test_plan_selection_rejects_cached_bare_and_unrelated_hosts(self):
        target = {"BlueprintName": "MingaTests", "TestBundlePath": "__TESTHOST__/Contents/PlugIns/MingaTests.xctest",
                  "TestHostPath": "__TESTROOT__/Debug/MingaTestHost.app"}
        plan = {"MingaTests": target, "__xctestrun_metadata__": {"FormatVersion": 1}}
        self.assertTrue(evidence.current_host_plan(plan))
        for host in ("", "/Developer/usr/bin/xctest", "__TESTROOT__/Debug/Minga.app",
                     "__TESTROOT__/Debug/MingaTestHost.app/Contents/MacOS/MingaTestHost"):
            changed = copy.deepcopy(plan)
            changed["MingaTests"]["TestHostPath"] = host
            with self.subTest(host=host):
                self.assertFalse(evidence.current_host_plan(changed))
        plan["OtherTests"] = copy.deepcopy(target)
        self.assertFalse(evidence.current_host_plan(plan))

    def test_relocated_xctestrun_injects_real_data_paths_and_preserves_binary_paths(self):
        for modern in (False, True):
            with self.subTest(modern=modern), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                products = root / "Products"
                products.mkdir()
                original = products / "Minga.xctestrun"
                target = {"TestBundlePath": "__TESTROOT__/Debug/MingaTests.xctest",
                          "EnvironmentVariables": {"KEEP": "existing"}}
                plan = {"MingaTests": target}
                if modern:
                    target["BlueprintName"] = "MingaTests"
                    plan = {"TestConfigurations": [{"TestTargets": [target]}]}
                original.write_bytes(plistlib.dumps(plan))
                destination = root / "replay.xctestrun"
                receipts, corpus = root / "receipts", root / "corpus"
                evidence.replay_plan(original, corpus, receipts, destination)
                rewritten = list(evidence.test_targets(plistlib.loads(destination.read_bytes())))[0]
                self.assertEqual(rewritten["TestBundlePath"], str(products / "Debug/MingaTests.xctest"))
                self.assertEqual(rewritten["EnvironmentVariables"], {
                    "KEEP": "existing", "MINGA_CONFORMANCE_CORPUS_DIR": str(corpus),
                    "MINGA_CONFORMANCE_REPLAY_RECEIPTS": str(receipts)})

    def test_receipts_must_equal_the_bytes_loaded_from_the_selected_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus, receipts = root / "corpus", root / "receipts"
            (corpus / "recovery").mkdir(parents=True)
            receipts.mkdir()
            entry = {"name": evidence.TARGET, "file": "recovery/" + evidence.TARGET + ".json"}
            source = ROOT / "test/conformance/corpus" / entry["file"]
            (corpus / entry["file"]).write_bytes(source.read_bytes())
            run = {"receipts": receipts.name, "log": "native.log"}
            with self.assertRaises(RuntimeError):
                evidence.verify_receipts(root, run, corpus, [entry])
            receipt = receipts / source.name
            receipt.write_text("wrong data")
            with self.assertRaises(RuntimeError):
                evidence.verify_receipts(root, run, corpus, [entry])
            receipt.write_bytes(source.read_bytes())
            evidence.verify_receipts(root, run, corpus, [entry])
            self.assertEqual(run["consumed_transcript_sha256"][evidence.TARGET], evidence.sha256(source))
            self.assertEqual(run["consumed_transcript_count"], 1)
            (receipts / "unselected.json").write_bytes(source.read_bytes())
            with self.assertRaises(RuntimeError):
                evidence.verify_receipts(root, run, corpus, [entry])

    def test_timing_counts_parameter_runs_not_logical_functions_on_the_same_destination(self):
        row = {"device": {"deviceId": "native-device"},
               "testPlanConfiguration": {"configurationId": "1"}, "passedTests": 38}
        before = {"summary": {"passedTests": 2, "devicesAndConfigurations": [row]}}
        after = copy.deepcopy(before)
        after["summary"]["devicesAndConfigurations"][0]["passedTests"] = 44
        self.assertEqual(evidence.paired_passed_runs(before, after), 6)
        for rows in (None, [], [row, row], [{"passedTests": 44}]):
            with self.subTest(rows=rows), self.assertRaises(RuntimeError):
                evidence.paired_passed_runs(before, {"summary": {"devicesAndConfigurations": rows}})
        for key in ("device", "testPlanConfiguration"):
            changed = copy.deepcopy(after)
            changed["summary"]["devicesAndConfigurations"][0][key] = {
                "deviceId": "another-device", "configurationId": "2"}
            with self.subTest(identity=key), self.assertRaises(RuntimeError):
                evidence.paired_passed_runs(before, changed)

    def test_timing_is_completed_suite_time_not_xcode_wall_time(self):
        self.assertEqual(evidence.suite_seconds('✔ Suite "Frontend conformance transcripts" passed after 20.125 seconds.'), 20.125)
        with self.assertRaises(RuntimeError):
            evidence.suite_seconds("xcodebuild exited after 20 seconds without a test suite")


if __name__ == "__main__":
    unittest.main()
