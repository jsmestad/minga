defmodule MingaEditor.UI.Picker.ExtensionSource do
  @moduledoc """
  Picker source for selecting a single extension to update.

  Lists all registered extensions with their source type, version, and
  status. Selecting an extension triggers an update check and apply for
  that extension only.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  @impl true
  @spec title() :: String.t()
  def title, do: "Extension"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    extensions = ExtSupervisor.list_extensions()
    all_entries = ExtRegistry.all()

    Enum.map(extensions, fn {name, version, status} ->
      source_label = source_description(name, all_entries)
      label = "#{name} v#{version} [#{status}]"
      %Item{id: name, label: label, description: source_label}
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) when is_atom(name) do
    alias Minga.Extension.Updater

    Task.start(fn ->
      Updater.check_single(name)
    end)

    MingaEditor.State.set_status(state, "Checking #{name} for updates...")
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec source_description(atom(), [{atom(), Minga.Extension.Entry.t()}]) :: String.t()
  defp source_description(name, all_entries) do
    case List.keyfind(all_entries, name, 0) do
      {_, %{source_type: :path}} -> "path"
      {_, %{source_type: :git, git: %{url: url}}} -> "git: #{url}"
      {_, %{source_type: :hex, hex: %{package: pkg}}} -> "hex: #{pkg}"
      _ -> "unknown"
    end
  end
end
