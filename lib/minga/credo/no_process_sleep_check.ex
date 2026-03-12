defmodule Minga.Credo.NoProcessSleepCheck do
  @moduledoc """
  Forbids `Process.sleep/1` in production code (`lib/`).

  ## Why this exists

  `Process.sleep` blocks the calling process, defeats the BEAM's
  concurrency model, and hides real timing bugs. It makes code
  impossible to test deterministically and creates subtle race
  conditions under load.

  Use `Process.send_after/3`, GenServer state machines, or `receive`
  with `after` clauses instead. If you need to defer work until a
  resource is ready, store the intent in state and act on it when the
  ready signal arrives (e.g., set a pending field and apply it in the
  `handle_info` that confirms the resource is up).

  `Process.sleep` in tests is acceptable only in integration tests
  that interact with external processes, where there is no message to
  wait for.

  See AGENTS.md § "Coding Standards" for the full rationale.
  """

  use Credo.Check,
    id: "EX9002",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `Process.sleep/1` must not appear in production code. It blocks the
      calling process and hides timing bugs.

      Use `Process.send_after/3` or GenServer state machines instead.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if test_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_process_sleep(&1, &2, issue_meta))
      |> List.flatten()
    end
  end

  # Match Process.sleep(...)
  defp find_process_sleep(
         {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    issue =
      format_issue(issue_meta,
        message:
          "Process.sleep/1 blocks the calling process. Use Process.send_after/3 or a GenServer state machine instead.",
        trigger: "Process.sleep",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp find_process_sleep(ast, issues, _issue_meta), do: {ast, issues}

  defp test_file?(%SourceFile{} = source_file) do
    source_file.filename
    |> Path.expand()
    |> String.contains?("/test/")
  end
end
