Code.require_file("credo/checks/explicit_target_check.exs")

defmodule Minga.Credo.ExplicitTargetCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.ExplicitTargetCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(code, params \\ []) do
    code
    |> to_source_file("lib/minga_editor/commands/example.ex")
    |> run_check(ExplicitTargetCheck, params)
  end

  test "a targeted clause cannot select its subject from active editor state" do
    for module <- [
          "MingaEditor.Commands.Example",
          "MingaEditor.Handlers.GuiActionHandler",
          "MingaEditor.Mouse",
          "MingaEditor.WindowFocus",
          "MingaEditor.TabWorkflow"
        ],
        target <- ["%Target{}", "%MingaEditor.Target{}"],
        read <- [
          "state.workspace.buffers.active",
          "state.workspace.windows.active",
          "state.active_id",
          "TabBar.active(state.tabs)",
          "Runtime.active_tab(state.shell_runtime)",
          "active_window(state)",
          "MingaEditor.State.active_window(state)"
        ] do
      """
      defmodule #{module} do
        def execute(state, #{target} = named) when is_map(state) do
          switch(state, named)
          #{read}
        end
      end
      """
      |> check()
      |> assert_issue()
    end
  end

  test "target reads in guards and implicit exception sections remain guarded" do
    for definition <- [
          "def execute(state, %Target{} = target) when state.workspace.buffers.active == target.item_id, do: state",
          "def execute(state, %Target{}) do state.workspace.buffers.active catch :exit, _ -> state end",
          "def execute(state, %Target{}) do state rescue _ -> state.workspace.buffers.active end"
        ] do
      """
      defmodule MingaEditor.Commands.Example do
        #{definition}
      end
      """
      |> check()
      |> assert_issue()
    end
  end

  test "active commands and comparison reads inside the owning state module remain valid" do
    """
    defmodule MingaEditor.Commands.Example do
      def execute(state, :kill_buffer), do: state.workspace.buffers.active
      def execute(state, %Target{} = named), do: close_named(state, named)
    end
    """
    |> check()
    |> refute_issues()

    """
    defmodule MingaEditor.State do
      def compare(state, %MingaEditor.Target{} = named) do
        state.workspace.buffers.active == named.item_id
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "the guard rejects index-addressed decoders including guarded clauses" do
    for head <- [
          "decode_gui_action(@gui_action_bad, <<position::16>>)",
          "decode_gui_action(@gui_action_bad, <<generation::32, position::16>>)",
          "decode_gui_action(@gui_action_bad, <<position::unsigned-16>>)",
          "decode_gui_action(@gui_action_bad, <<position::unsigned-integer-size(16)>>)",
          "decode_gui_action(@gui_action_bad, <<item_id::16>>)",
          "decode_gui_action(@gui_action_bad, <<position::16-unit(1)>>)",
          "decode_gui_action(@gui_action_bad, <<position::size(8)-unit(2)>>)",
          "decode_gui_action(@gui_action_bad, <<position::16>> = payload)",
          "decode_gui_action(@gui_action_bad, payload = <<position::16>>)",
          "decode_gui_action(@gui_action_bad, <<position::16>>) when position > 0"
        ] do
      """
      defmodule MingaEditor.Frontend.Protocol.GUI do
        def #{head}, do: {:ok, position}
      end
      """
      |> check()
      |> assert_issue()
    end
  end

  test "binary lengths and identity-bearing activations are not positions" do
    for payload <- [
          "<<path_len::16, path::binary-size(path_len)>>",
          "<<id::32, position::16>>",
          "<<token::binary-size(16)>>",
          "<<position::signed-16>>",
          "<<id::unsigned-size(32), position::16>>",
          "<<generation::32, item_id_len::16, item_id::binary-size(item_id_len)>>"
        ] do
      """
      defmodule MingaEditor.Frontend.Protocol.GUI do
        def decode_gui_action(@gui_action_named, #{payload}), do: :ok
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  test "tab reorder is the sole built-in position exception" do
    """
    defmodule MingaEditor.Frontend.Protocol.GUI do
      def decode_gui_action(@gui_action_tab_reorder, <<id::32, new_index::16>>), do: :ok
    end
    """
    |> check()
    |> refute_issues()
  end

  test "existing narrow identities need a reasoned capped exemption" do
    code = """
    defmodule MingaEditor.Frontend.Protocol.GUI do
      def decode_gui_action(@gui_action_workspace_close, <<ws_id::16>>), do: :ok
    end
    """

    code |> check() |> assert_issue()

    code
    |> check(
      identity_opcodes: [gui_action_workspace_close: "Stable workspace identity, not an index."]
    )
    |> refute_issues()

    source = to_source_file(code, "lib/minga_editor/frontend/protocol/gui.ex")

    assert_raise ArgumentError, fn ->
      ExplicitTargetCheck.run(source, identity_opcodes: [gui_action_workspace_close: ""])
    end

    assert_raise ArgumentError, fn ->
      ExplicitTargetCheck.run(source, identity_opcodes: List.duplicate({:name, "reason"}, 11))
    end
  end

  test "each production decoder clause obeys the registered identity contract" do
    {config, _} = Code.eval_file(".credo.exs")

    {_check, params} =
      Enum.find(hd(config.configs).checks.enabled, fn {module, _} ->
        module == ExplicitTargetCheck
      end)

    ast = "lib/minga_editor/frontend/protocol/gui.ex" |> File.read!() |> Code.string_to_quoted!()

    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, _blocks]} = clause, clauses ->
          case unguard(head) do
            {:decode_gui_action, _, _args} -> {clause, [clause | clauses]}
            _ -> {clause, clauses}
          end

        node, clauses ->
          {node, clauses}
      end)

    for clause <- clauses do
      """
      defmodule MingaEditor.Frontend.Protocol.GUI do
        #{Macro.to_string(clause)}
      end
      """
      |> check(params)
      |> refute_issues()
    end
  end

  defp unguard({:when, _, [head | _]}), do: unguard(head)
  defp unguard(head), do: head
end
