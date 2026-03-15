defmodule Minga.Picker.LanguageSource do
  @moduledoc """
  Picker source for changing the active buffer's language (major mode).

  Lists all registered languages from the Language registry with icons,
  extensions, and the current language highlighted. Selecting a language
  changes the buffer's filetype, re-seeds per-filetype options, and
  triggers a tree-sitter reparse.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Language
  alias Minga.Language.Registry, as: LangRegistry
  alias Minga.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Set language"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(state) do
    current_ft = current_filetype(state)

    LangRegistry.all()
    |> Enum.map(fn %Language{} = lang -> format_candidate(lang, current_ft) end)
    |> Enum.sort_by(& &1.label)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: filetype}, state) when is_atom(filetype) do
    BufferManagement.apply_filetype_change(state, filetype)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec format_candidate(Language.t(), atom()) :: Item.t()
  defp format_candidate(%Language{} = lang, current_ft) do
    {icon, color} = Devicon.icon_and_color(lang.name)
    exts = format_extensions(lang.extensions)
    current = if lang.name == current_ft, do: " •", else: ""

    %Item{
      id: lang.name,
      label: "#{icon} #{lang.label}#{current}",
      description: exts,
      icon_color: color
    }
  end

  @spec format_extensions([String.t()]) :: String.t()
  defp format_extensions([]), do: ""

  defp format_extensions(exts) do
    exts
    |> Enum.take(4)
    |> Enum.map_join(", ", &".#{&1}")
  end

  @spec current_filetype(term()) :: atom()
  defp current_filetype(%{buffers: %{active: buf}}) when is_pid(buf) do
    if Process.alive?(buf), do: BufferServer.filetype(buf), else: :text
  end

  defp current_filetype(_state), do: :text
end
