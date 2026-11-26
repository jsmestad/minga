defmodule MingaEditor.RenderModel.UI.QueueBuilder do
  @moduledoc false

  alias MingaAgent.Session.QueuedInputSummary
  alias Minga.RenderModel.UI.Queue
  alias MingaEditor.Agent.QueueSurface
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.EmptyStateBuilder
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @close_hint {"q", "close", :close}

  @spec build(Context.t(), boolean()) :: Queue.t()
  def build(%Context{workspace: %{agent_ui: %{queue: queue}}} = ctx, true) do
    if QueueSurface.visible?(queue), do: visible(ctx, queue), else: %Queue{}
  end

  def build(%Context{}, false), do: %Queue{}

  @spec visible(Context.t(), QueueSurface.t()) :: Queue.t()
  defp visible(ctx, %QueueSurface{origin: {workspace, _, record}} = queue) do
    model = %Queue{
      visible?: true,
      focused?: QueueSurface.focused?(queue),
      workspace_id: workspace,
      record_id: record,
      title: QueueSurface.buffer_name()
    }

    present_contents(model, queue, stopped?(ctx))
  end

  @spec present_contents(Queue.t(), QueueSurface.t(), boolean()) :: Queue.t()
  defp present_contents(model, %{contents: nil}, _stopped),
    do: %{model | summary: "Loading queue…", hints: [@close_hint]}

  defp present_contents(model, %{contents: :unavailable}, _stopped),
    do: %{model | summary: "Queue unavailable", hints: [@close_hint]}

  defp present_contents(model, %{contents: %{pending: [], removed: []}}, _stopped) do
    empty =
      EmptyStateBuilder.empty_list(
        "Nothing queued.",
        "Messages queued while Minga works wait here.",
        [
          {:queue_return_to_composer, "Back to the composer", "↩"}
        ]
      )

    %{model | summary: "Queue", hints: [@close_hint], empty: empty}
  end

  defp present_contents(model, %{contents: contents, selected_id: selected}, stopped) do
    %{
      model
      | summary: summary(length(contents.pending), stopped),
        removed_note: removed_note(contents.removed),
        selected_id: selected,
        hints: row_hints(model.focused?, contents.pending, contents.removed),
        pending: Enum.with_index(contents.pending, &row(&1, &2 + 1)),
        removed: Enum.with_index(contents.removed, &row(&1, &2 + 1))
    }
  end

  @spec stopped?(Context.t()) :: boolean()
  defp stopped?(%Context{intent: %{frame: %{shell_state: %TraditionalState{} = shell}}}),
    do: TraditionalState.agent(shell).runtime.status == :stopped

  defp stopped?(%Context{}), do: false

  @spec summary(non_neg_integer(), boolean()) :: String.t()
  defp summary(count, true) when count > 0, do: "#{count} queued, kept"
  defp summary(count, _stopped), do: "#{count} queued"

  @spec removed_note([QueuedInputSummary.t()]) :: String.t()
  defp removed_note([]), do: ""
  defp removed_note(_removed), do: "Removed, not sent. Up to eight, until you close Minga."

  @spec row_hints(boolean(), [QueuedInputSummary.t()], [QueuedInputSummary.t()]) :: [Queue.hint()]
  defp row_hints(false, _waiting, _removed), do: []
  defp row_hints(true, [], []), do: [@close_hint]
  defp row_hints(true, [], [_ | _]), do: [{"p", "put back", :paste_after}, @close_hint]

  defp row_hints(true, [_ | _], []) do
    [{"dd", "remove", :remove}, {"↩", "edit", :edit}, @close_hint]
  end

  defp row_hints(true, [_ | _], [_ | _]) do
    [
      {"dd", "remove", :remove},
      {"p", "after", :paste_after},
      {"P", "before", :paste_before},
      {"↩", "edit", :edit},
      @close_hint
    ]
  end

  @spec row(QueuedInputSummary.t(), pos_integer()) :: Queue.row()
  defp row(%QueuedInputSummary{identity: {id, revision}} = entry, index) do
    preview = entry.preview |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ") |> String.trim()

    %{
      id: id,
      revision: revision,
      kind: entry.kind,
      label: Integer.to_string(index),
      preview: if(preview == "", do: "Attachment-only input", else: preview),
      attachment_count: entry.attachment_count
    }
  end
end
