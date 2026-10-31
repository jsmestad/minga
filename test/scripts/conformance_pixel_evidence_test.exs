defmodule Minga.ConformancePixelEvidenceTest do
  # Python uses a BEAM OS port; serialize to avoid concurrent erl_child_setup races.
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check_conformance_pixels", __DIR__)

  test "pixel timing counts parameter executions on the same native destination" do
    python = ~S"""
    import copy, runpy, sys
    delta = runpy.run_path(sys.argv[1])["paired_passed_runs"]
    row = {"device": {"deviceId": "native-device"},
           "testPlanConfiguration": {"configurationId": "1"}, "passedTests": 44}
    before = {"summary": {"passedTests": 2, "devicesAndConfigurations": [row]}}
    after = copy.deepcopy(before)
    after["summary"]["passedTests"] = 3
    after["summary"]["devicesAndConfigurations"][0]["passedTests"] = 47
    assert delta(before, after) == 3
    for rows in (None, [], [row, row], [{"passedTests": 47}]):
        try:
            delta(before, {"summary": {"devicesAndConfigurations": rows}})
        except RuntimeError:
            pass
        else:
            raise AssertionError("Missing or ambiguous native execution counts were accepted")
    after["summary"]["devicesAndConfigurations"][0]["device"]["deviceId"] = "another-device"
    try:
        delta(before, after)
    except RuntimeError:
        pass
    else:
        raise AssertionError("A different native destination was accepted as a paired measurement")
    """

    {output, status} = System.cmd("python3", ["-c", python, @script], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "pixel mutations require only evaluated production behavioral failures after a clean control" do
    python = ~S"""
    import copy, runpy, sys
    evidence = runpy.run_path(sys.argv[1])
    classify = evidence["native_behavioral_failure"]
    geometry = ("Expectation failed: (abs(rect.minY - 4 * spacedHeight) → 12.8) < 0.001\n"
                "[pixels3520.spacing.ime-row]")
    scroll = ("Expectation failed: (draw.unconfirmedLines → 2) == 1\n"
              "[pixels3520.scroll.acknowledged-lines]")
    def tree(case, result):
        return {"testNodes": [{"nodeType": "Test Plan", "name": "Minga", "result": result, "children": [
            {"nodeType": "Unit test bundle", "name": "MingaTests", "result": result, "children": [
                {"nodeType": "Test Suite", "name": "Content view",
                 "nodeIdentifierURL": "test://com.apple.xcode/Minga/MingaTests/ContentViewTests",
                 "result": result, "children": [case]}]}]}]}
    def selected(run):
        return run["tests"]["testNodes"][0]["children"][0]["children"][0]["children"][0]
    def execution(run, kind):
        case = selected(run)
        return case["children"][0] if kind == "spacing" else case
    for kind, diagnostic in (("spacing", geometry), ("scroll", scroll)):
        name = evidence["BEHAVIORAL_FAILURES"][kind][0]
        identifier = "ContentViewTests/" + name + ("(spacing:)" if kind == "spacing" else "()")
        url = "test://com.apple.xcode/Minga/MingaTests/" + identifier
        case = {"nodeType": "Test Case", "nodeIdentifier": identifier, "nodeIdentifierURL": url,
                "result": "Passed", "children": []}
        if kind == "spacing":
            case["children"] = [{"nodeType": "Arguments", "name": "1.2", "result": "Passed"}]
        control = {"exit_code": 0,
                   "summary": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "result": "Passed"},
                   "tests": tree(case, "Passed")}
        failed_case = copy.deepcopy(case)
        failed_case["result"] = "Failed"
        failure = {"failureText": diagnostic, "targetName": "MingaTests",
                   "testIdentifierString": identifier, "testIdentifierURL": url}
        mutant = {"exit_code": 65,
                  "summary": {"failedTests": 1, "testFailures": [failure]},
                  "tests": tree(failed_case, "Failed")}
        failed_execution = execution(mutant, kind)
        failed_execution["result"] = "Failed"
        failed_execution["children"] = [{"nodeType": "Failure Message",
                                        "name": "ContentViewTests.swift:974: " + diagnostic}]
        assert classify(control, mutant, kind)
        for message in (
            "Expectation failed: CoreTextMetalRenderer(factories:) → nil",
            "Requirement failed: Metal shader library unavailable",
            "Test crashed with signal 11",
            diagnostic + "\nFatal error: renderer crashed",
            diagnostic.split("\n")[-1],
            "Expectation failed: " + diagnostic.split("\n")[-1],
            "Expectation failed: unrelated == false\n" + diagnostic.split("\n")[-1],
            "",
        ):
            broken = copy.deepcopy(mutant)
            broken["summary"]["testFailures"][0]["failureText"] = message
            assert not classify(control, broken, kind), message
        for extra in ("Requirement failed: Metal device unavailable",
                      "Expectation failed: unrelated view assertion",
                      "Test crashed with signal 11", ""):
            broken = copy.deepcopy(mutant)
            broken["summary"]["testFailures"].append(dict(failure, failureText=extra))
            assert not classify(control, broken, kind), extra
            broken = copy.deepcopy(mutant)
            execution(broken, kind)["children"].append({"nodeType": "Failure Message", "name": extra})
            assert not classify(control, broken, kind), extra
        for field in ("testIdentifierString", "testIdentifierURL"):
            broken = copy.deepcopy(mutant)
            broken["summary"]["testFailures"][0][field] = (
                "ContentViewTests/unrelated()" if field.endswith("String")
                else "test://com.apple.xcode/Minga/MingaTests/ContentViewTests/unrelated()")
            assert not classify(control, broken, kind), field
            del broken["summary"]["testFailures"][0][field]
            assert not classify(control, broken, kind), field
        for failures in (None, [], [{}], [{"failureText": None}], ["unknown"]):
            broken = copy.deepcopy(mutant)
            broken["summary"]["testFailures"] = failures
            assert not classify(control, broken, kind)
        for changes in ({"exit_code": 0}, {"exit_code": -11}, {"tests": None}):
            assert not classify(control, dict(mutant, **changes), kind)
        for change in ("passed-case-failed-ancestor", "unrelated-failure", "prefixed-case",
                       "no-tree-diagnostic", "diagnostic-outside-case"):
            broken = copy.deepcopy(mutant)
            if change == "passed-case-failed-ancestor":
                selected(broken)["result"] = "Passed"
                broken["tests"]["testNodes"][0]["name"] = identifier
            elif change == "unrelated-failure":
                suite = broken["tests"]["testNodes"][0]["children"][0]["children"][0]
                suite["children"].append({"nodeType": "Test Case", "nodeIdentifier": "ContentViewTests/unrelated()",
                                          "result": "Failed"})
            elif change == "prefixed-case":
                selected(broken)["nodeIdentifier"] = "ContentViewTests/" + name + "Extra()"
            elif change == "no-tree-diagnostic":
                execution(broken, kind)["children"] = []
            else:
                diagnostic_node = execution(broken, kind)["children"].pop()
                broken["tests"]["testNodes"][0]["children"].append(diagnostic_node)
            assert not classify(control, broken, kind), change
        broken = copy.deepcopy(mutant)
        broken["summary"]["failedTests"] = 2
        assert not classify(control, broken, kind)
        broken_control = copy.deepcopy(control)
        selected(broken_control)["result"] = "Failed"
        assert not classify(broken_control, mutant, kind)
        broken_control = copy.deepcopy(control)
        broken_control["summary"]["testFailures"] = [{"failureText": "unexpected setup issue"}]
        assert not classify(broken_control, mutant, kind)
        broken_control = copy.deepcopy(control)
        selected(broken_control)["children"].append({"nodeType": "Failure Message", "name": diagnostic})
        assert not classify(broken_control, mutant, kind)
        warning = {"nodeType": "Runtime Warning", "name": "Multiple Runtime Warnings"}
        selected(control)["children"].append(warning)
        selected(mutant)["children"].append(copy.deepcopy(warning))
        assert classify(control, mutant, kind)
        assert not classify(control, mutant, "unknown")
    """

    {output, status} = System.cmd("python3", ["-c", python, @script], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "selected evidence requires complete clean trees and all three named pixel executions" do
    python = ~S"""
    import copy, runpy, sys
    evidence = runpy.run_path(sys.argv[1])
    clean = evidence["clean_selected_run"]
    def case(name, children=None):
        node = {"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"}
        if children is not None:
            node["children"] = children
        return node
    ordinary = case("ConformanceTranscriptTests/runsTranscript(_:)",
                    [{"nodeType": "Arguments", "name": "keyframe_decode", "result": "Passed"}])
    replay = case("replay(_:)", [{"nodeType": "Arguments", "name": name, "result": "Passed"}
                                for name in sorted(evidence["PIXEL_CASES"])])
    pixels = {"nodeType": "Test Suite", "nodeIdentifier": "ConformanceTranscriptTests.Pixels",
              "result": "Passed", "children": [replay]}
    full = {"exit_code": 0,
            "summary": {"totalTestCount": 5, "passedTests": 5, "failedTests": 0, "result": "Passed"},
            "tests": {"testNodes": [{"nodeType": "Test Suite", "nodeIdentifier": "ConformanceTranscriptTests",
                                    "result": "Passed", "children": [ordinary, pixels, case("corpusIsPopulated()")]}]}}
    without = copy.deepcopy(full)
    without["tests"]["testNodes"][0]["children"].pop(1)
    assert clean(full, "with_pixels")
    assert clean(without, "without_pixels")
    assert not clean(full, "without_pixels")
    assert not clean(without, "with_pixels")
    for run, selection in ((without, "without_pixels"), (full, "with_pixels")):
        broken = copy.deepcopy(run)
        broken["tests"]["testNodes"][0]["children"][0]["children"] = []
        assert not clean(broken, selection)
        broken = copy.deepcopy(run)
        broken["tests"]["testNodes"][0]["children"].append(
            {"nodeType": "Failure Message", "name": "ContentViewTests.swift:974: unexpected setup failure"})
        assert not clean(broken, selection)
        warning = copy.deepcopy(run)
        warning["tests"]["testNodes"][0]["children"].append(
            {"nodeType": "Runtime Warning", "name": "Multiple Runtime Warnings"})
        assert clean(warning, selection)
    for missing in (0, 1):
        broken = copy.deepcopy(without)
        broken["tests"]["testNodes"][0]["children"].pop(missing)
        assert not clean(broken, "without_pixels")
    for tree in (None, {}, {"testNodes": []}, {"testNodes": "corrupt"},
                 {"testNodes": [None]}, {"testNodes": [{"nodeType": "Test Case", "children": []}]}):
        broken = dict(full, tests=tree)
        assert not clean(broken, "with_pixels")
        assert not clean(broken, "without_pixels")
    broken = dict(full, extraction_errors=["tests: JSON decoding failed after summary success"])
    assert not clean(broken, "with_pixels")
    for modification in ("missing", "wrong", "failed", "duplicate", "wrong-parent", "malformed",
                         "unrelated", "unknown-type", "wrong-kind"):
        broken = copy.deepcopy(full)
        actual = broken["tests"]["testNodes"][0]["children"][1]["children"][0]
        if modification == "missing":
            actual["children"].pop()
        elif modification == "wrong":
            actual["children"][0]["name"] += "_not_the_case"
        elif modification == "failed":
            actual["children"][0]["result"] = "Failed"
        elif modification == "duplicate":
            actual["children"].append(copy.deepcopy(actual["children"][0]))
        elif modification == "wrong-parent":
            actual["nodeIdentifier"] = "unrelatedFunction()"
        elif modification == "malformed":
            actual["children"] = "unreadable"
        elif modification == "unknown-type":
            broken["tests"]["testNodes"].append({
                "nodeType": "Unknown Execution", "nodeIdentifier": "UnrelatedSuite/passing()", "result": "Passed"})
        elif modification == "wrong-kind":
            actual["children"][0]["nodeType"] = "Test Case"
        else:
            broken["tests"]["testNodes"].append(case("UnrelatedSuite/passing()"))
        assert not clean(broken, "with_pixels"), modification
    for kind, (name, _) in evidence["BEHAVIORAL_FAILURES"].items():
        named = copy.deepcopy(full)
        named["tests"]["testNodes"] = [case("ContentViewTests/" + name + "()")]
        assert clean(named, kind)
        for tree in (None, {}, {"testNodes": []}, {"testNodes": [case("ContentViewTests/not_selected()")]}):
            assert not clean(dict(named, tests=tree), kind)
        assert not clean(dict(named, extraction_errors=["summary: corrupt"]), kind)
        misleading = copy.deepcopy(named)
        misleading["tests"]["testNodes"] = [
            {"nodeType": "Test Suite", "nodeIdentifier": "ContentViewTests/" + name,
             "result": "Passed", "children": [case("ContentViewTests/unrelated()")]}]
        assert not clean(misleading, kind)
        prefixed = copy.deepcopy(named)
        prefixed["tests"]["testNodes"] = [case("ContentViewTests/" + name + "Extra()")]
        assert not clean(prefixed, kind)
        named["tests"]["testNodes"].append(case("UnrelatedSuite/passing()"))
        assert not clean(named, kind)
    """

    {output, status} = System.cmd("python3", ["-c", python, @script], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "evidence rejects tracked and untracked production sources but not generated outputs" do
    python = ~S"""
    import runpy, sys
    changes = runpy.run_path(sys.argv[1])["source_guard_changes"]
    relevant = ["scripts/check_conformance_pixels", "scripts/test_macos_unit",
                "macos/Sources/Renderer/EditorPresentation.swift", "macos/Tests/MingaTests/NewTest.swift",
                "macos/project.yml", "macos/Minga.xcodeproj/project.pbxproj", "test/conformance/corpus/index.json",
                "lib/mix/tasks/conformance/pixel_scenarios.ex", "mix/protocol_generator.ex",
                "config/test.exs", "mix.exs", "mix.lock", ".tool-versions", ".gitignore",
                "docs/protocol_schema.toml", ".github/workflows/ci.yml"]
    for path in relevant:
        assert changes([path], []) == {"tracked": [path], "untracked": []}, path
        assert changes([], [path]) == {"tracked": [], "untracked": [path]}, path
    outputs = ["_build/dev/compiled.beam", "deps/a/lib/source.ex", "macos/DerivedData/result.json",
               "macos/.generated/protocol/ProtocolOpcodes.generated.swift", "conformance-pixel-evidence/evidence.json",
               "conformance-recovery-evidence/evidence.json", "macos-unit-evidence/results.json",
               ".generated/protocol/source.ex", "test/tmp/scratch.ex", "scripts/__pycache__/collector.pyc"]
    assert changes(outputs, outputs) == {"tracked": [], "untracked": []}
    assert changes([], []) == {"tracked": [], "untracked": []}
    """

    {output, status} = System.cmd("python3", ["-c", python, @script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
