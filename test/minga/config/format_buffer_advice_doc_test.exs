defmodule Minga.Config.FormatBufferAdviceDocTest do
  # Runs the `advise :around, :format_buffer` example from docs/CONFIGURATION.md
  # through the same advice chain the editor uses, with real editor state.
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Config.Advice
  alias MingaEditor.Extension.EditorAPI

  # Copied from the "Command advice" example in docs/CONFIGURATION.md.
  # If the doc changes, update this copy.
  defp documented_advice do
    fn execute, state ->
      errors =
        state
        |> EditorAPI.active_buffer()
        |> Minga.Diagnostics.for_buffer()
        |> Enum.count(fn d -> d.severity == :error end)

      if errors == 0 do
        execute.(state)
      else
        EditorAPI.notice(state, "Format skipped: #{errors} error(s)")
      end
    end
  end

  setup do
    table = :"format_buffer_doc_advice_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    :ok = Advice.register(table, :around, :format_buffer, documented_advice())

    test_pid = self()

    execute = fn state ->
      send(test_pid, :format_ran)
      state
    end

    %{wrapped: Advice.wrap(table, :format_buffer, execute)}
  end

  test "documented snippet runs the command for a scratch buffer", %{wrapped: wrapped} do
    state = base_state(content: "scratch text")

    assert wrapped.(state) == state
    assert_received :format_ran
  end

  test "documented snippet runs the command for a file-backed buffer with no diagnostics", %{
    wrapped: wrapped
  } do
    path = Path.join(System.tmp_dir!(), "format_doc_#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule Clean do\nend\n")
    on_exit(fn -> File.rm(path) end)

    state = base_state(content: "original") |> EditorAPI.open_file(path)

    assert wrapped.(state) == state
    assert_received :format_ran
  end

  test "documented :override snippet replaces format_buffer and reports it" do
    table = :"format_buffer_doc_override_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    # Copied from the `:override` example in docs/CONFIGURATION.md.
    :ok =
      Advice.register(table, :override, :format_buffer, fn state ->
        MingaEditor.Extension.EditorAPI.notice(state, "Formatting is off in this project")
      end)

    test_pid = self()

    original = fn state ->
      send(test_pid, :format_ran)
      state
    end

    state = base_state(content: "scratch text")

    assert Advice.wrap(table, :format_buffer, original).(state) ==
             EditorAPI.notice(state, "Formatting is off in this project")

    refute_received :format_ran
  end
end
