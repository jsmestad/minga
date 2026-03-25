defmodule Minga.Tool.PickerSource do
  @moduledoc """
  Picker source for browsing and installing tools.

  Shows all available tools with their install status. The picker stays
  open after selecting a tool so the user can see status changes in real
  time and install multiple tools in one session.

  Accessible via `SPC c l I` (Manage tools).
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Manage Tools"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec layout() :: :centered
  def layout, do: :centered

  @impl true
  @spec keep_open_on_select?() :: boolean()
  def keep_open_on_select?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    statuses = ToolManager.tool_status_list()

    Enum.map(statuses, fn %{recipe: recipe, status: status, installed_version: version} ->
      icon = category_icon(recipe.category)
      status_badge = status_badge(status, version)
      languages = Enum.map_join(recipe.languages, ", ", &Atom.to_string/1)

      label = "#{icon} #{recipe.label} #{status_badge}"
      description = "#{recipe.description} [#{languages}]"

      %Item{
        id: {recipe.name, status},
        label: label,
        description: description,
        icon_color: status_color(status)
      }
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {name, :not_installed}}, state) do
    case ToolManager.install(name) do
      :ok ->
        Minga.Editor.State.set_status(state, "Installing #{name}...")

      {:error, reason} ->
        Minga.Editor.State.set_status(state, "Cannot install #{name}: #{reason}")
    end
  end

  def on_select(%Item{id: {name, :installed}}, state) do
    Minga.Editor.State.set_status(state, "#{name} is already installed. Press C-o for actions.")
  end

  def on_select(%Item{id: {name, :update_available}}, state) do
    case ToolManager.update(name) do
      :ok -> Minga.Editor.State.set_status(state, "Updating #{name}...")
      {:error, reason} -> Minga.Editor.State.set_status(state, "Cannot update #{name}: #{reason}")
    end
  end

  def on_select(%Item{id: {name, :installing}}, state) do
    Minga.Editor.State.set_status(state, "#{name} is currently being installed...")
  end

  def on_select(%Item{id: {name, :failed}}, state) do
    # Retry on failed tool
    case ToolManager.install(name) do
      :ok ->
        Minga.Editor.State.set_status(state, "Retrying #{name}...")

      {:error, reason} ->
        Minga.Editor.State.set_status(state, "Cannot install #{name}: #{reason}")
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @impl true
  @spec actions(Item.t()) :: [Minga.UI.Picker.Source.action_entry()]
  def actions(%Item{id: {_name, :installed}}) do
    [{"Uninstall", :uninstall}, {"Update", :update}]
  end

  def actions(%Item{id: {_name, :not_installed}}) do
    [{"Install", :install}]
  end

  def actions(%Item{id: {_name, :failed}}) do
    [{"Retry", :install}]
  end

  def actions(_), do: []

  @impl true
  @spec on_action(atom(), Item.t(), term()) :: term()
  def on_action(:install, %Item{id: {name, _}}, state) do
    case ToolManager.install(name) do
      :ok -> Minga.Editor.State.set_status(state, "Installing #{name}...")
      {:error, reason} -> Minga.Editor.State.set_status(state, "Cannot install: #{reason}")
    end
  end

  def on_action(:uninstall, %Item{id: {name, _}}, state) do
    case ToolManager.uninstall(name) do
      :ok -> Minga.Editor.State.set_status(state, "Uninstalled #{name}")
      {:error, reason} -> Minga.Editor.State.set_status(state, "Cannot uninstall: #{reason}")
    end
  end

  def on_action(:update, %Item{id: {name, _}}, state) do
    case ToolManager.update(name) do
      :ok -> Minga.Editor.State.set_status(state, "Updating #{name}...")
      {:error, reason} -> Minga.Editor.State.set_status(state, "Cannot update: #{reason}")
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec category_icon(atom()) :: String.t()
  defp category_icon(:lsp_server), do: "󰒋"
  defp category_icon(:formatter), do: "󰉼"
  defp category_icon(:linter), do: "󰛩"
  defp category_icon(:debugger), do: "󰃤"

  @spec status_badge(atom(), String.t() | nil) :: String.t()
  defp status_badge(:installed, version), do: "✓ v#{version}"
  defp status_badge(:installing, _), do: "⟳ installing..."
  defp status_badge(:update_available, version), do: "↑ v#{version}"
  defp status_badge(:not_installed, _), do: ""
  defp status_badge(:failed, _), do: "✕ failed"

  @spec status_color(atom()) :: non_neg_integer()
  defp status_color(:installed), do: 0x50FA7B
  defp status_color(:installing), do: 0xF1FA8C
  defp status_color(:update_available), do: 0xFFB86C
  defp status_color(:not_installed), do: 0x6272A4
  defp status_color(:failed), do: 0xFF6E6E
end
