defmodule MingaEditor.UI.Picker.GitLogFileSource do
  @moduledoc """
  Current-file variant of the git log picker source.

  This source delegates display and preview behavior to `GitLogSource` after deriving the active buffer's git root and relative path from the picker context.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Git
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.GitLogSource
  alias MingaEditor.UI.Picker.Item

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
  def candidates(%Context{buffers: %{active: buf}} = ctx) when is_pid(buf) do
    case Git.tracking_pid(buf) do
      nil -> []
      git_pid -> candidates_for_git_buffer(ctx, git_pid)
    end
  catch
    :exit, _ -> []
  end

  def candidates(_ctx), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  defdelegate on_select(item, state), to: GitLogSource

  @impl true
  @spec on_cancel(term()) :: term()
  defdelegate on_cancel(state), to: GitLogSource

  @impl true
  @spec preview(Item.t(), MingaEditor.Frontend.Emit.Context.t()) ::
          [
            [MingaEditor.UI.Picker.Source.preview_segment()]
          ]
          | nil
  defdelegate preview(item, ctx), to: GitLogSource

  @spec candidates_for_git_buffer(Context.t(), pid()) :: [Item.t()]
  defp candidates_for_git_buffer(ctx, git_pid) do
    context =
      %{
        git_root: Git.Buffer.git_root(git_pid),
        path: Git.Buffer.relative_path(git_pid),
        source: __MODULE__
      }
      |> maybe_put_count(ctx)

    ctx
    |> Context.with_picker_context(context)
    |> GitLogSource.candidates()
  end

  @spec maybe_put_count(map(), Context.t()) :: map()
  defp maybe_put_count(context, %Context{picker_ui: %{context: %{count: count}}})
       when is_integer(count) and count > 0 do
    Map.put(context, :count, count)
  end

  defp maybe_put_count(context, _ctx), do: context
end
