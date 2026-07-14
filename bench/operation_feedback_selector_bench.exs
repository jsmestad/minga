# Benchmark: bounded operation-feedback selection.
#
# Measures selection across the full retained collection for both precedence
# paths: newest active operation and newest terminal fallback.
#
# Run: mix run bench/operation_feedback_selector_bench.exs

alias MingaEditor.State.OperationFeedback

limit = 32

full_active =
  Enum.reduce(1..limit, OperationFeedback.new(limit), fn index, feedback ->
    {feedback, operation} =
      OperationFeedback.start(
        feedback,
        :lsp_references,
        "resource-#{index}",
        "Operation #{index}",
        replace?: false
      )

    case rem(index, 4) do
      0 -> feedback
      _remainder -> OperationFeedback.finish(feedback, operation.id, :success, "Done")
    end
  end)

full_terminal =
  Enum.reduce(1..limit, OperationFeedback.new(limit), fn index, feedback ->
    {feedback, operation} =
      OperationFeedback.start(
        feedback,
        :lsp_references,
        "resource-#{index}",
        "Operation #{index}",
        replace?: false
      )

    OperationFeedback.finish(feedback, operation.id, :success, "Done")
  end)

Benchee.run(
  %{"selected/1" => fn feedback -> OperationFeedback.selected(feedback) end},
  inputs: %{
    "full retained, active precedence" => full_active,
    "full retained, terminal fallback" => full_terminal
  },
  warmup: 2,
  time: 5,
  memory_time: 2,
  reduction_time: 2,
  formatters: [Benchee.Formatters.Console],
  print: [benchmarking: true, configuration: true, fast_warning: true]
)
