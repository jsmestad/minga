defmodule MingaEditor.UI.Picker.GitLogSource do
  @moduledoc """
  Picker source for browsing recent git commits with diff previews.

  The source powers the project log picker and the current-file log picker. Commit rows stay compact, while the GUI picker preview pane shows the selected commit's patch via the existing picker preview protocol.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Git
  alias Minga.Log
  alias MingaEditor.Frontend.Emit.Context, as: EmitContext
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @default_count 50
  @load_more_step 50
  @default_fg 0xCCCCCC
  @hash_fg 0x61AFEF
  @header_fg 0xC678DD
  @hunk_fg 0x56B6C2
  @added_fg 0x98C379
  @deleted_fg 0xE06C75

  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @impl true
  @spec title() :: String.t()
  def title, do: "Git Log"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec live_preview?() :: boolean()
  def live_preview?, do: false

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = ctx) do
    case git_root(ctx) do
      {:ok, git_root} -> build_candidates(git_root, picker_path(ctx), picker_count(ctx), picker_source(ctx))
      :not_git -> []
    end
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{id: {:git_log_load_more, source_module, git_root, path, count}}, state)
      when is_atom(source_module) do
    PickerUI.open(state, source_module, load_more_context(git_root, path, count, source_module))
  end

  def on_select(%Item{id: {:git_log_load_more, git_root, path, count}}, state) do
    PickerUI.open(state, __MODULE__, load_more_context(git_root, path, count, __MODULE__))
  end

  def on_select(%Item{id: {:git_log_commit, _git_root, hash, _path}}, state) do
    EditorState.set_status(state, "Git commit #{String.slice(hash, 0, 12)}")
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @impl true
  @spec preview(Item.t(), EmitContext.t()) :: [[preview_segment()]] | nil
  def preview(%Item{id: {:git_log_commit, git_root, hash, path}}, ctx) do
    case Git.diff(git_root, diff_opts(hash, path)) do
      {:ok, ""} -> [[{"No diff for this commit", preview_fg(ctx), false}]]
      {:ok, diff} -> diff_preview_lines(diff, ctx)
      {:error, reason} -> [[{"Failed to load diff: #{reason}", @deleted_fg, false}]]
    end
  end

  def preview(_item, _ctx), do: nil

  @spec build_candidates(String.t(), String.t() | nil, pos_integer(), module()) :: [Item.t()]
  defp build_candidates(git_root, path, count, source_module) do
    case Git.log(git_root, count: count + 1, path: path) do
      {:ok, entries} -> format_entries(entries, git_root, path, count, source_module)
      {:error, reason} -> log_failure(reason)
    end
  end

  @spec format_entries([Git.log_entry()], String.t(), String.t() | nil, pos_integer(), module()) :: [
          Item.t()
        ]
  defp format_entries(entries, git_root, path, count, source_module) do
    visible_entries = Enum.take(entries, count)
    items = Enum.map(visible_entries, &format_entry(&1, git_root, path))

    if length(entries) > count do
      items ++ [load_more_item(git_root, path, count + @load_more_step, source_module)]
    else
      items
    end
  end

  @spec format_entry(Git.log_entry(), String.t(), String.t() | nil) :: Item.t()
  defp format_entry(entry, git_root, path) do
    %Item{
      id: {:git_log_commit, git_root, entry.hash, path},
      label: entry.message,
      description: "#{entry.author} · #{entry.date}",
      annotation: entry.short_hash,
      search_text: "#{entry.hash} #{entry.short_hash} #{entry.author} #{entry.message}"
    }
  end

  @spec load_more_item(String.t(), String.t() | nil, pos_integer(), module()) :: Item.t()
  defp load_more_item(git_root, path, count, source_module) do
    %Item{
      id: {:git_log_load_more, source_module, git_root, path, count},
      label: "Load more...",
      description: "Show #{count} commits",
      annotation: "+#{@load_more_step}"
    }
  end

  @spec log_failure(String.t()) :: []
  defp log_failure(reason) do
    Log.warning(:editor, "[git_log_picker] git log failed: #{reason}")
    []
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

  @spec picker_path(Context.t()) :: String.t() | nil
  defp picker_path(%Context{picker_ui: %{context: %{path: path}}}) when is_binary(path), do: path
  defp picker_path(_ctx), do: nil

  @spec picker_count(Context.t()) :: pos_integer()
  defp picker_count(%Context{picker_ui: %{context: %{count: count}}})
       when is_integer(count) and count > 0,
       do: count

  defp picker_count(_ctx), do: @default_count

  @spec load_more_context(String.t(), String.t() | nil, pos_integer(), module()) :: map()
  defp load_more_context(git_root, nil, count, source_module),
    do: %{git_root: git_root, count: count, source: source_module}

  defp load_more_context(git_root, path, count, source_module),
    do: %{git_root: git_root, path: path, count: count, source: source_module}

  @spec diff_opts(String.t(), String.t() | nil) :: keyword()
  defp diff_opts(hash, nil), do: [commit: hash]
  defp diff_opts(hash, path), do: [commit: hash, path: path]

  @spec diff_preview_lines(String.t(), EmitContext.t()) :: [[preview_segment()]]
  defp diff_preview_lines(diff, ctx) do
    diff
    |> String.split("\n")
    |> Enum.take(200)
    |> Enum.map(&style_diff_line(&1, ctx))
  end

  @spec style_diff_line(String.t(), EmitContext.t()) :: [preview_segment()]
  defp style_diff_line("diff --git" <> _ = line, _ctx), do: [{line, @header_fg, true}]
  defp style_diff_line("@@" <> _ = line, _ctx), do: [{line, @hunk_fg, true}]
  defp style_diff_line("+++" <> _ = line, _ctx), do: [{line, @hash_fg, true}]
  defp style_diff_line("---" <> _ = line, _ctx), do: [{line, @hash_fg, true}]
  defp style_diff_line("+" <> _ = line, _ctx), do: [{line, @added_fg, false}]
  defp style_diff_line("-" <> _ = line, _ctx), do: [{line, @deleted_fg, false}]
  defp style_diff_line(line, ctx), do: [{line, preview_fg(ctx), false}]

  @spec preview_fg(EmitContext.t()) :: non_neg_integer()
  defp preview_fg(%{theme: theme}) when is_map(theme), do: Map.get(theme, :fg, @default_fg)
  defp preview_fg(_ctx), do: @default_fg

  @spec picker_source(Context.t()) :: module()
  defp picker_source(%Context{picker_ui: %{context: %{source: source}}}) when is_atom(source), do: source
  defp picker_source(_ctx), do: __MODULE__
end
