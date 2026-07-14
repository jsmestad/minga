Code.require_file("credo/checks/editor_state_ownership_check.exs")

defmodule Minga.Credo.EditorStateOwnershipCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.EditorStateOwnershipCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename \\ "lib/minga_editor/example.ex", params \\ []) do
    source_code
    |> to_source_file(filename)
    |> run_check(EditorStateOwnershipCheck, params)
  end

  test "flags a foreign explicit update to a leaf-owned struct" do
    """
    defmodule MingaEditor.BadRenderTransition do
      def clear(correlation) do
        %MingaEditor.State.RenderCorrelation{correlation | timer: nil}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation"
      assert issue.message =~ "owner MingaEditor.State.RenderCorrelation"
      assert issue.message =~ "MingaEditor.State.RenderCorrelation transition API"
    end)
  end

  test "flags a foreign map update when a function pattern binds its struct type" do
    """
    defmodule MingaEditor.BadTypedTransition do
      alias MingaEditor.State.RenderCorrelation

      def clear(%RenderCorrelation{} = value), do: %{value | timer: nil}
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation"
      assert issue.message =~ "outside its owner"
    end)
  end

  test "flags a foreign map update when a branch pattern binds its struct type" do
    """
    defmodule MingaEditor.BadBranchTransition do
      alias MingaEditor.State.RenderCorrelation

      def clear(correlation) do
        case correlation do
          %RenderCorrelation{} = value -> %{value | timer: nil}
          _unknown -> correlation
        end
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation"
      assert issue.message =~ "outside its owner"
    end)
  end

  test "keeps branch struct bindings lexical and source ordered" do
    source =
      """
      defmodule MingaEditor.LexicalBranchTransition do
        alias MingaEditor.State.RenderCorrelation

        def clear(value, correlation) do
          earlier = %{value | timer: nil}

          branch =
            case correlation do
              %RenderCorrelation{} = typed -> %{typed | timer: nil}
              _sibling -> %{value | timer: nil}
            end

          {earlier, branch, %{value | timer: nil}}
        end
      end
      """

    issues = check(source)

    assert Enum.count(issues, &(&1.trigger == "MingaEditor.State.RenderCorrelation")) == 1
  end

  test "flags an aggregate update when a receiver path identifies Session.State" do
    """
    defmodule MingaEditor.BadAggregateTransition do
      def replace_editing(state, editing) do
        %{state.workspace | editing: editing}
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.Session.State"
      assert issue.message =~ "aggregate transition API"
    end)
  end

  test "allows a workflow to install a value produced by the focused root-field owner" do
    """
    defmodule MingaEditor.RenderWorkflow do
      def invalidate(%MingaEditor.State{} = state) do
        %{state | render: MingaEditor.State.Render.invalidate_layout(state.render)}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "flags raw and wrong-owner root-field replacements" do
    source =
      """
      defmodule MingaEditor.BadRootInstallation do
        def replace_raw(%MingaEditor.State{} = state, render), do: %{state | render: render}

        def replace_from_wrong_owner(%MingaEditor.State{} = state) do
          %{state | render: MingaEditor.State.Parser.retire_buffer(state.parser, self())}
        end
      end
      """

    issues = check(source)

    assert Enum.count(issues, &(&1.trigger == "MingaEditor.State")) == 2
  end

  test "requires every field in a root update to be produced by its focused owner" do
    """
    defmodule MingaEditor.BadMixedRootInstallation do
      def replace(%MingaEditor.State{} = state, parser) do
        %{
          state
          | render: MingaEditor.State.Render.invalidate_layout(state.render),
            parser: parser
        }
      end
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "MingaEditor.State" end)
  end

  test "flags foreign writes from workflow and root callers" do
    workflow =
      """
      defmodule MingaEditor.ExampleWorkflow do
        def schedule(correlation, timer) do
          %MingaEditor.State.RenderCorrelation{correlation | timer: timer}
        end
      end
      """

    root =
      """
      defmodule MingaEditor.State do
        def replace_file_tree(state, file_tree) do
          %{state.workspace | file_tree: file_tree}
        end
      end
      """

    workflow
    |> check("lib/minga_editor/example_workflow.ex")
    |> assert_issue()

    root
    |> check("lib/minga_editor/state.ex")
    |> assert_issue(fn issue ->
      assert issue.message =~ "MingaEditor.Session.State"
    end)
  end

  test "flags clear put_in update_in and Map.put ownership paths" do
    source =
      """
      defmodule MingaEditor.BadPathWrites do
        def put_hidden(state), do: put_in(state.workspace.file_tree.hidden, true)
        def update_tree(state, fun), do: update_in(state.workspace.file_tree, fun)
        def put_workspace(state, editing), do: Map.put(state.workspace, :editing, editing)
      end
      """

    issues = check(source)

    assert Enum.count(issues, &(&1.trigger == "MingaEditor.State.FileTree")) == 2
    assert Enum.count(issues, &(&1.trigger == "MingaEditor.Session.State")) == 1
  end

  test "flags the most specific owner for a nested update_in path" do
    """
    defmodule MingaEditor.BadNestedPathWrite do
      def clear_refresh_timer(state, fun) do
        update_in(state.workspace.file_tree.refresh.timer, fun)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.FileTree.Refresh"
      assert issue.message =~ "MingaEditor.State.FileTree.Refresh transition API"
    end)
  end

  test "does not infer an owned type from an unknown variable" do
    """
    defmodule MingaEditor.UnknownValue do
      def replace(workspace, editing) do
        %{workspace | editing: editing}
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "allows writes in the designated leaf and aggregate owners" do
    leaf =
      """
      defmodule MingaEditor.State.RenderCorrelation do
        def clear(value) do
          %__MODULE__{value | timer: nil}
        end
      end
      """

    aggregate =
      """
      defmodule MingaEditor.Session.State do
        def replace_editing(workspace, editing) do
          %__MODULE__{workspace | editing: editing}
        end
      end
      """

    leaf |> check("lib/minga_editor/state/render_correlation.ex") |> refute_issues()
    aggregate |> check("lib/minga_editor/session/state.ex") |> refute_issues()
  end

  test "flags process timer task logging rendering persistence and service calls in pure owners" do
    calls = [
      "Process.send_after(self(), :tick, 10)",
      "Task.start(fn -> :ok end)",
      "Minga.Log.info(:editor, \"changed\")",
      "MingaEditor.Renderer.render(value)",
      "File.write(\"state\", value)",
      "Minga.Buffer.content(value)"
    ]

    Enum.each(calls, fn call ->
      source =
        """
        defmodule MingaEditor.State.RenderCorrelation do
          def violate(value) do
            #{call}
            value
          end
        end
        """

      issues = check(source, "lib/minga_editor/state/render_correlation.ex")
      assert issues != [], "expected a purity issue for #{call}"

      assert_issue(issues, fn issue ->
        assert issue.message =~ "Pure owner MingaEditor.State.RenderCorrelation"
        assert issue.message =~ "move this work to MingaEditor.RenderPipeline"
      end)
    end)
  end

  test "flags Registry and Minga storage boundaries in pure owners" do
    calls = [
      "Registry.lookup(Minga.Registry, value)",
      "Minga.Extension.Storage.put(:editor, value)",
      "Minga.Persistence.Snapshots.save(value)"
    ]

    Enum.each(calls, fn call ->
      source =
        """
        defmodule MingaEditor.State.RenderCorrelation do
          def violate(value) do
            #{call}
            value
          end
        end
        """

      issues = check(source, "lib/minga_editor/state/render_correlation.ex")
      assert issues != [], "expected a purity issue for #{call}"
      assert_issue(issues, fn issue -> assert issue.message =~ "prohibited external boundary" end)
    end)
  end

  test "resolves unrestricted and selected Registry imports in pure owners" do
    sources = [
      """
      defmodule MingaEditor.State.RenderCorrelation do
        import Registry

        def violate(value), do: lookup(Minga.Registry, value)
      end
      """,
      """
      defmodule MingaEditor.State.RenderCorrelation do
        import Registry, only: [register: 3]

        def violate(value), do: register(Minga.Registry, value, :registered)
      end
      """
    ]

    Enum.each(sources, fn source ->
      source
      |> check("lib/minga_editor/state/render_correlation.ex")
      |> assert_issue(fn issue -> assert issue.trigger =~ "Registry." end)
    end)
  end

  test "enforces purity for every designated UIState owner" do
    """
    defmodule MingaEditor.Agent.UIState.Presentation do
      def persist(value) do
        MingaEditor.Extension.Storage.save(value)
        value
      end
    end
    """
    |> check("lib/minga_editor/agent/ui_state/presentation.ex")
    |> assert_issue(fn issue ->
      assert issue.message =~ "Pure owner MingaEditor.Agent.UIState.Presentation"
      assert issue.trigger == "MingaEditor.Extension.Storage.save"
    end)
  end

  test "enforces every converged top-level owner path" do
    owners = [
      {"MingaEditor.State.Frontend", "frontend"},
      {"MingaEditor.State.Render", "render"},
      {"MingaEditor.State.Parser", "parser"},
      {"MingaEditor.State.AgentConnection", "agent_connection"},
      {"MingaEditor.State.Interaction", "interaction"},
      {"MingaEditor.State.ExtensionSurfaces", "extension_surfaces"},
      {"MingaEditor.State.BufferLifecycle", "buffer_lifecycle"},
      {"MingaEditor.State.Git", "git"},
      {"MingaEditor.State.Session", "session"},
      {"MingaEditor.State.Feedback", "feedback"},
      {"MingaEditor.State.LSP", "lsp"},
      {"MingaEditor.State.Remote", "remote"},
      {"MingaEditor.State.Appearance", "appearance"}
    ]

    Enum.each(owners, fn {owner, path} ->
      foreign = """
      defmodule MingaEditor.ForeignOwnerWriter do
        def write(state, value), do: %{state.#{path} | value: value}
      end
      """

      foreign
      |> check("lib/minga_editor/foreign_owner_writer.ex")
      |> assert_issue(fn issue ->
        assert issue.trigger == owner
        assert issue.message =~ "outside its owner"
      end)

      generic = """
      defmodule #{owner} do
        def update(value, fun) when is_function(fun, 1), do: fun.(value)
      end
      """

      generic
      |> check("lib/minga_editor/state/owner.ex")
      |> assert_issue(fn issue ->
        assert issue.trigger == "#{owner}.update/2"
        assert issue.message =~ "Generic mutation API"
      end)
    end)
  end

  test "rejects external boundary calls in every converged pure owner" do
    owners = [
      "MingaEditor.State.Frontend",
      "MingaEditor.State.Render",
      "MingaEditor.State.Parser",
      "MingaEditor.State.AgentConnection",
      "MingaEditor.State.Interaction",
      "MingaEditor.State.ExtensionSurfaces",
      "MingaEditor.State.BufferLifecycle",
      "MingaEditor.State.Git",
      "MingaEditor.State.Session",
      "MingaEditor.State.Feedback",
      "MingaEditor.State.LSP",
      "MingaEditor.State.Remote",
      "MingaEditor.State.Appearance"
    ]

    Enum.each(owners, fn owner ->
      source = """
      defmodule #{owner} do
        def schedule(value), do: {Process.send_after(self(), :tick, 10), value}
      end
      """

      source
      |> check("lib/minga_editor/state/owner.ex")
      |> assert_issue(fn issue ->
        assert issue.trigger == "Process.send_after"
        assert issue.message =~ "Pure owner #{owner}"
      end)
    end)
  end

  test "allows converged owner writes and focused workflow effects" do
    owner_source = """
    defmodule MingaEditor.State.Frontend do
      def accept(value, next), do: %__MODULE__{value | backend: next}
    end
    """

    owner_source
    |> check("lib/minga_editor/state/frontend.ex")
    |> refute_issues()

    """
    defmodule MingaEditor.FrontendWorkflow do
      def schedule do
        Process.send_after(self(), :frame, 10)
      end
    end
    """
    |> check("lib/minga_editor/frontend_workflow.ex")
    |> refute_issues()
  end

  test "allows pure constructors and owner-to-owner value calls" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def reset(value, file_tree, tree, buffer) do
        next_tree = MingaEditor.State.FileTree.open(file_tree, tree, buffer)
        {%__MODULE__{value | timer: nil}, next_tree}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> refute_issues()
  end

  test "flags external boundary calls from pure owners without exceptions" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def start_buffer(value, opts) do
        {value, Minga.Buffer.start_link(opts)}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "Minga.Buffer.start_link"
      assert issue.message =~ "prohibited external boundary"
    end)
  end

  test "allows pure owner-to-owner transition calls" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def replace_editing(value, workspace, editing) do
        {value, MingaEditor.Session.State.replace_editing(workspace, editing)}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> refute_issues()
  end

  test "allows external work in a workflow module" do
    """
    defmodule MingaEditor.RenderPipeline do
      def schedule(value) do
        timer = Process.send_after(self(), :render, 10)
        MingaEditor.Renderer.render(value)
        timer
      end
    end
    """
    |> check("lib/minga_editor/render_pipeline.ex")
    |> refute_issues()
  end

  test "rejects a public generic mutation API in an owner" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def update(value, fun) when is_function(fun, 1), do: fun.(value)
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation.update/2"
      assert issue.message =~ "Generic mutation API"
      assert issue.message =~ "encodes its invariant"
    end)
  end

  test "rejects canonical Access callbacks and equivalent arbitrary mutation APIs" do
    callbacks = [
      "def fetch(value, key), do: Map.fetch(value, key)",
      "def get_and_update(value, key, fun), do: Map.get_and_update(value, key, fun)",
      "def pop(value, key), do: Map.pop(value, key)",
      "def transform(value, key, fun), do: fun.(Map.fetch!(value, key))"
    ]

    Enum.each(callbacks, fn callback ->
      source =
        """
        defmodule MingaEditor.State.RenderCorrelation do
          #{callback}
        end
        """

      issues = check(source, "lib/minga_editor/state/render_correlation.ex")
      assert issues != [], "expected a generic API issue for #{callback}"
      assert_issue(issues, fn issue -> assert issue.message =~ "Generic mutation API" end)
    end)
  end

  test "rejects renamed arbitrary mutation APIs from body structure" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def revise(subject, slot, operation) do
        operation.(Map.fetch!(subject, slot))
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation.revise/3"
      assert issue.message =~ "Generic mutation API"
    end)
  end

  test "rejects guarded arbitrary dynamic-key mutation APIs" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def revise(subject, slot, replacement) when is_atom(slot) do
        Map.put(subject, slot, replacement)
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "MingaEditor.State.RenderCorrelation.revise/3"
      assert issue.message =~ "Generic mutation API"
    end)
  end

  test "allows a focused owner transition even when its name starts with set" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def set_receipt_revision(value, revision) do
        %__MODULE__{value | latest_receipt_revision: revision}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> refute_issues()
  end

  test "allows a focused owner transition despite a generic argument name" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def record_receipt_key(value, key) do
        %__MODULE__{value | latest_receipt_revision: key}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> refute_issues()
  end

  test "allows a focused owner transition with a function argument named by domain intent" do
    """
    defmodule MingaEditor.State.RenderCorrelation do
      def record_receipt(value, receipt) do
        %__MODULE__{value | latest_receipt_revision: receipt.revision}
      end
    end
    """
    |> check("lib/minga_editor/state/render_correlation.ex")
    |> refute_issues()
  end

  test "an exact documented legacy entry suppresses only its named site" do
    params = [
      allowlist: [
        [
          module: "MingaEditor.LegacyRender",
          function: "clear/1",
          violation: "direct_write",
          target: "MingaEditor.State.RenderCorrelation",
          ticket: "#2870",
          reason: "Legacy render transition awaiting final convergence",
          invariant: "Only render timer state changes at this legacy boundary"
        ]
      ]
    ]

    allowed =
      """
      defmodule MingaEditor.LegacyRender do
        def clear(value) do
          %MingaEditor.State.RenderCorrelation{value | timer: nil}
        end
      end
      """

    rejected = String.replace(allowed, "def clear", "def replace")

    allowed |> check("lib/minga_editor/legacy_render.ex", params) |> refute_issues()
    rejected |> check("lib/minga_editor/legacy_render.ex", params) |> assert_issue()
  end

  test "rejects broad or undocumented allowlist entries" do
    source =
      """
      defmodule MingaEditor.State.RenderCorrelation do
        def scheduled?(value), do: value.timer != nil
      end
      """

    broad = [
      allowlist: [
        [
          module: "MingaEditor.*",
          function: "clear/1",
          violation: "direct_write",
          target: "MingaEditor.State.RenderCorrelation",
          ticket: "#2870",
          reason: "Broad legacy exception that must not be accepted",
          invariant: "Only render timer state changes at this legacy boundary"
        ]
      ]
    ]

    undocumented = [
      allowlist: [
        [
          module: "MingaEditor.LegacyRender",
          function: "clear/1",
          violation: "direct_write",
          target: "MingaEditor.State.RenderCorrelation",
          ticket: "#2870",
          reason: "legacy",
          invariant: "Only render timer state changes at this legacy boundary"
        ]
      ]
    ]

    source
    |> check("lib/minga_editor/state/render_correlation.ex", broad)
    |> assert_issue(fn issue -> assert issue.message =~ "wildcards and paths are forbidden" end)

    source
    |> check("lib/minga_editor/state/render_correlation.ex", undocumented)
    |> assert_issue(fn issue ->
      assert issue.message =~ "migration ticket, reason, and invariant"
    end)
  end
end
