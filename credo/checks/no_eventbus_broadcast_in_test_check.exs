defmodule Minga.Credo.NoEventBusBroadcastInTestCheck do
  @moduledoc """
  Flags `EventBus.broadcast` and `Minga.EventBus.broadcast` calls inside test files.

  The live application emits real events on the global EventBus during test runs, causing flaky `assert_receive` matches. Tests should use `Minga.Events.subscribers/1` assertions or an isolated registry via `start_supervised!({Minga.Events, name: unique_name})`.
  """

  use Credo.Check,
    id: "EX9009",
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `EventBus.broadcast` in tests causes flaky `assert_receive` matches because the live application emits real events on the global EventBus during test runs.

      Use `Minga.Events.subscribers/1` assertions or an isolated registry via `start_supervised!({Minga.Events, name: unique_name})` instead.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_broadcast(&1, &2, issue_meta))
      |> List.flatten()
    else
      []
    end
  end

  # Match EventBus.broadcast(...)
  defp find_broadcast(
         {{:., _, [{:__aliases__, _, [:EventBus]}, :broadcast]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [make_issue(issue_meta, "EventBus.broadcast", meta[:line]) | issues]}
  end

  # Match Minga.EventBus.broadcast(...)
  defp find_broadcast(
         {{:., _, [{:__aliases__, _, [:Minga, :EventBus]}, :broadcast]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [make_issue(issue_meta, "Minga.EventBus.broadcast", meta[:line]) | issues]}
  end

  defp find_broadcast(ast, issues, _issue_meta), do: {ast, issues}

  defp make_issue(issue_meta, trigger, line_no) do
    format_issue(issue_meta,
      message:
        "#{trigger} in tests causes flaky assert_receive matches. Use Minga.Events.subscribers/1 or an isolated registry instead.",
      trigger: trigger,
      line_no: line_no
    )
  end

  defp test_file?(%SourceFile{} = source_file) do
    source_file.filename
    |> Path.expand()
    |> String.contains?("/test/")
  end
end
