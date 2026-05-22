defmodule MingaEditor.UI.Picker.GitStashSource do
  @moduledoc """
  Picker source for browsing and dropping git stashes.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Git
  alias Minga.Log
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Git Stashes"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = ctx) do
    case git_root(ctx) do
      {:ok, git_root} -> build_candidates(git_root, stash_action(ctx))
      :not_git -> []
    end
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{id: {:stash, git_root, index, :drop}}, state) do
    drop_stash(git_root, index, state)
  end

  def on_select(%Item{id: {:stash, _git_root, _index, _action}, label: label}, state) do
    EditorState.set_status(state, "Stash: #{label}")
  end

  def on_select(_, state), do: state

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(%Item{id: {:stash, _git_root, _index, _action}}), do: [{"Drop", :drop}]
  def actions(_item), do: []

  @impl true
  @spec on_action(atom(), Item.t(), EditorState.t()) :: EditorState.t()
  def on_action(:drop, %Item{id: {:stash, git_root, index, _action}}, state) do
    drop_stash(git_root, index, state)
  end

  def on_action(_action, _item, state), do: state

  @typep stash_action :: :list | :drop

  @spec build_candidates(String.t(), stash_action()) :: [Item.t()]
  defp build_candidates(git_root, action) do
    case Git.stash_list(git_root) do
      {:ok, entries} -> Enum.map(entries, &format_entry(&1, git_root, action))
      {:error, reason} -> log_failure(reason)
    end
  end

  @spec format_entry(Git.stash_entry(), String.t(), stash_action()) :: Item.t()
  defp format_entry(entry, git_root, action) do
    %Item{
      id: {:stash, git_root, entry.index, action},
      label: entry.message,
      description: entry.date,
      annotation: entry.ref
    }
  end

  @spec git_root(Context.t()) :: {:ok, String.t()} | :not_git
  defp git_root(%Context{picker_ui: %{context: %{git_root: git_root}}})
       when is_binary(git_root) do
    {:ok, git_root}
  end

  defp git_root(_ctx) do
    Minga.Project.resolve_root()
    |> Git.root_for()
  end

  @spec stash_action(Context.t()) :: stash_action()
  defp stash_action(%Context{picker_ui: %{context: %{action: :drop}}}), do: :drop
  defp stash_action(_ctx), do: :list

  @spec log_failure(String.t()) :: []
  defp log_failure(reason) do
    Log.warning(:editor, "[git_stash_picker] stash_list failed: #{reason}")
    []
  end

  @spec drop_stash(String.t(), non_neg_integer(), EditorState.t()) :: EditorState.t()
  defp drop_stash(git_root, index, state) do
    case Git.stash_drop(git_root, index) do
      :ok ->
        refresh_repo(git_root)
        EditorState.set_status(state, "Dropped stash@{#{index}}")

      {:error, reason} ->
        EditorState.set_status(state, "Drop stash failed: #{reason}")
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.refresh_repo(pid)
    end
  end
end
