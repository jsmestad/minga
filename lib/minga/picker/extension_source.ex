defmodule Minga.Picker.ExtensionSource do
  @moduledoc """
  Picker source for selecting a single extension to update.

  Lists all registered extensions with their source type, version, and
  status. Selecting an extension triggers an update check and apply for
  that extension only.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  @impl true
  @spec title() :: String.t()
  def title, do: "Extension"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    extensions = ExtSupervisor.list_extensions()
    all_entries = ExtRegistry.all()

    Enum.map(extensions, fn {name, version, status} ->
      source_label = source_description(name, all_entries)
      label = "#{name} v#{version} [#{status}]"
      {name, label, source_label}
    end)
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({name, _label, _desc}, state) when is_atom(name) do
    alias Minga.Extension.Updater

    Task.start(fn ->
      Updater.update_single(name)
    end)

    %{state | status_msg: "Checking #{name} for updates..."}
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
