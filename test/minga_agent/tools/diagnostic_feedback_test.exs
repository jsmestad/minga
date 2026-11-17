defmodule MingaAgent.Tools.DiagnosticFeedbackTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.DiagnosticFeedback

  @moduletag :tmp_dir

  test "successful atomic tool mutations retain optional diagnostic feedback", %{tmp_dir: root} do
    options = start_supervised!({Minga.Config.Options, name: nil})
    Process.put(:minga_config_options, options)
    assert {:ok, true} = Minga.Config.Options.set(options, :agent_diagnostic_feedback, true)
    File.write!(Path.join(root, "code.txt"), "one two")
    changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: root})
    retained = MingaAgent.Test.RetainedContextFixture.new(root, "diagnostic-feedback")

    context =
      MingaAgent.Tool.Context.new(
        project_root: root,
        changeset: changeset,
        artifact_store: retained.artifact_store
      )

    assert {:ok, output} = call(context, "read_file", %{"path" => "code.txt"})
    revision = MingaAgent.Tool.Output.Revision.token(output.revision)

    assert {:ok, message} =
             call(context, "edit_file", %{
               "path" => "code.txt",
               "expected_revision" => revision,
               "edits" => [%{"old_text" => "one", "new_text" => "ONE"}]
             })

    assert message =~ "(No LSP diagnostics available for this file.)"

    assert {:error, failure} =
             call(context, "edit_file", %{
               "path" => "code.txt",
               "expected_revision" => revision,
               "edits" => [%{"old_text" => "two", "new_text" => "TWO"}]
             })

    refute failure =~ "No LSP diagnostics"
    assert {:ok, output} = call(context, "read_file", %{"path" => "code.txt"})

    assert {:ok, message} =
             call(context, "write_file", %{
               "path" => "code.txt",
               "mode" => "replace",
               "content" => "replacement",
               "expected_revision" => MingaAgent.Tool.Output.Revision.token(output.revision)
             })

    assert message =~ "(No LSP diagnostics available for this file.)"
    assert {:ok, false} = Minga.Config.Options.set(options, :agent_diagnostic_feedback, false)
    assert {:ok, output} = call(context, "read_file", %{"path" => "code.txt"})

    assert {:ok, message} =
             call(context, "edit_file", %{
               "path" => "code.txt",
               "expected_revision" => MingaAgent.Tool.Output.Revision.token(output.revision),
               "edits" => [%{"old_text" => "replacement", "new_text" => "done"}]
             })

    refute message =~ "No LSP diagnostics"
    assert {:ok, "done"} = MingaAgent.Changeset.read_file(changeset, "code.txt")
    assert File.read!(Path.join(root, "code.txt")) == "one two"
  end

  describe "await/2 without LSP" do
    test "returns skip when no buffer exists for the path" do
      assert {:skip, reason} = DiagnosticFeedback.await("/nonexistent/file.ex")
      assert reason =~ "No LSP diagnostics"
    end
  end

  describe "append_to_result/2" do
    test "appends ok result with diagnostics" do
      result =
        DiagnosticFeedback.append_to_result(
          "edited foo.ex",
          {:ok, "Diagnostics: clean"}
        )

      assert result == "edited foo.ex\n\nDiagnostics: clean"
    end

    test "appends skip result in parentheses" do
      result =
        DiagnosticFeedback.append_to_result(
          "edited foo.ex",
          {:skip, "No LSP diagnostics available for this file."}
        )

      assert result == "edited foo.ex\n\n(No LSP diagnostics available for this file.)"
    end
  end

  defp call(context, name, args) do
    spec = Enum.find(MingaAgent.Tools.all(), &(&1.name == name))

    scoped =
      MingaAgent.Tool.Context.for_tool_call(
        context,
        context.artifact_store,
        "diagnostic-feedback",
        "call-#{System.unique_integer([:positive])}"
      )

    MingaAgent.Tool.Spec.build_callback(spec, scoped).(args)
  end
end
