defmodule MingaEditor.UI.Picker.ProjectRemoveSource do
  @moduledoc """
  Picker source for removing a known project.

  Mirrors Doom Projectile's remove-known-project flow: pick a known project,
  then confirm before deleting it from the known-projects list.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Project
  alias MingaEditor.PromptUI
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @max_prompt_bytes 255
  @remove_prefix "Remove "
  @remove_suffix "? (y/n): "
  @ellipsis "…"

  @impl true
  @spec title() :: String.t()
  def title, do: "Remove project"

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    Project.known_projects()
    |> Enum.map(&item/1)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: root_path}, state) when is_binary(root_path) do
    label = confirmation_label(root_path)

    PromptUI.open(state, MingaEditor.UI.Prompt.ProjectRemoveConfirm,
      label: label,
      context: %{path: root_path}
    )
  end

  @doc false
  @spec confirmation_label(String.t()) :: String.t()
  def confirmation_label(root_path) when is_binary(root_path) do
    name = truncate_for_prompt(Path.basename(root_path), available_name_bytes())
    @remove_prefix <> name <> @remove_suffix
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec item(String.t()) :: Item.t()
  defp item(root) do
    %Item{id: root, label: Path.basename(root), description: root}
  end

  @spec available_name_bytes() :: pos_integer()
  defp available_name_bytes do
    @max_prompt_bytes - byte_size(@remove_prefix) - byte_size(@remove_suffix)
  end

  @spec truncate_for_prompt(String.t(), pos_integer()) :: String.t()
  defp truncate_for_prompt(name, max_bytes) do
    if byte_size(name) <= max_bytes do
      name
    else
      do_truncate_for_prompt(name, max_bytes - byte_size(@ellipsis), "") <> @ellipsis
    end
  end

  @spec do_truncate_for_prompt(String.t(), non_neg_integer(), String.t()) :: String.t()
  defp do_truncate_for_prompt(_name, max_bytes, acc) when max_bytes <= 0, do: acc

  defp do_truncate_for_prompt(name, max_bytes, acc) do
    case String.next_grapheme(name) do
      {grapheme, rest} ->
        next = acc <> grapheme

        if byte_size(next) <= max_bytes do
          do_truncate_for_prompt(rest, max_bytes, next)
        else
          acc
        end

      nil ->
        acc
    end
  end
end
