defmodule Minga.Test.NextStepsPickerSource do
  @moduledoc "Test picker source that lists the labels in its open context and offers two next steps when nothing matches."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Next steps"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{labels: labels}}}),
    do: Enum.map(labels, &%Item{id: {:label, &1}, label: &1})

  @impl true
  @spec empty(Empty.request()) :: Empty.t()
  def empty(%{query: query, total: total}) do
    %Empty{
      typing?: total > 0,
      title:
        if(total == 0, do: "Nothing here yet.", else: "Nothing matches #{Empty.quoted(query)}."),
      why: "This source lists what its context gives it.",
      rows: [
        Empty.command_row(:project_add, "Add a folder"),
        Empty.command_row(:find_file, "Open a file")
      ]
    }
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, _step}} = item, state), do: Empty.run_command(item, state)
  def on_select(%Item{}, state), do: state
end
