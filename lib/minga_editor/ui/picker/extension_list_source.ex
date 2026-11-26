defmodule MingaEditor.UI.Picker.ExtensionListSource do
  @moduledoc """
  Picker source for `SPC h e l`: the installed extensions, with their version, status and where they come from.

  With none installed, it says what extensions are for and offers to open your config, where extensions are declared.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Extensions"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    entries = ExtRegistry.all()

    for {name, version, status} <- ExtSupervisor.list_extensions() do
      %Item{
        id: {:extension, name},
        label: to_string(name),
        description: "v#{version} · #{status} · #{source_label(name, entries)}"
      }
    end
  end

  @impl true
  @spec empty(Empty.request()) :: Empty.t()
  def empty(%{query: query, total: total}) do
    title =
      case {total, String.trim(query)} do
        {0, _query} -> "No extensions installed."
        {_total, name} -> "No extension matches #{Empty.quoted(name)}."
      end

    %Empty{
      typing?: total > 0,
      title: title,
      why: "Extensions add languages, tools and commands.",
      rows: [Empty.command_row(:open_config, "Open your config")]
    }
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, _step}} = item, state), do: Empty.run_command(item, state)

  def on_select(%Item{label: name, description: details}, state),
    do: MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "#{name} #{details}")

  @spec source_label(atom(), [{atom(), Minga.Extension.Entry.t()}]) :: String.t()
  defp source_label(name, entries) do
    case List.keyfind(entries, name, 0) do
      {_, %{source: {:path, path}}} -> "path: #{path}"
      {_, %{source: {:git, %{url: url}}}} -> "git: #{url}"
      {_, %{source: {:hex, %{package: pkg}}}} -> "hex: #{pkg}"
      _ -> "unknown source"
    end
  end
end
