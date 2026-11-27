defmodule MingaEditor.Extension.GitDiff do
  @moduledoc """
  Opens and projects semantic Git diff views from explicit text snapshots.

  The editor owns the generated buffer, decorations, navigation, and exact
  hunk selection. The calling extension chooses the snapshots and any Git
  operation; this module never reads or mutates a repository.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Git
  alias Minga.Language
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitDiff.Decoration
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target
  alias MingaEditor.Extension.GitDiff.View
  alias MingaEditor.Frontend
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State.Git, as: GitState

  @type state :: EditorAPI.state()
  @type change_result :: {:ok, state()} | {:error, term()}
  @type target_result :: nil | {:ok, Target.t()} | {:error, {:stale_source, Target.t()}}
  @typep cursor :: {non_neg_integer(), non_neg_integer()}

  @doc "Opens and activates a unified diff for exact base and revised texts."
  @spec open(state(), Origin.t(), Target.contents()) :: change_result()
  def open(state, %Origin{} = origin, {base, current} = contents)
      when (is_binary(base) or is_nil(base)) and (is_binary(current) or is_nil(current)) do
    with {:ok, version} <- admit_source(origin, current) do
      {view, text} = View.build(origin, contents, version, :unified, pane_width(state))
      open_buffer(state, view, text, nil)
    end
  end

  @doc "Replaces the exact snapshots in a named view, preserving its projection."
  @spec replace(state(), pid(), Origin.section(), Target.contents()) :: change_result()
  def replace(state, diff_buffer, section, {base, current} = contents)
      when is_pid(diff_buffer) and section in [:unstaged, :staged, :conflict] and
             (is_binary(base) or is_nil(base)) and (is_binary(current) or is_nil(current)) do
    with {:ok, view} <- fetch_view(state, diff_buffer),
         {:ok, cursor} <- diff_cursor(diff_buffer),
         origin = %{View.origin(view) | section: section},
         {:ok, version} <- admit_source(origin, current) do
      replace_snapshot(state, diff_buffer, view, origin, contents, version, cursor)
    end
  end

  @doc "Reprojects the displayed snapshots. Side-by-side is available on GUI frontends."
  @spec set_layout(state(), pid(), Target.layout()) :: change_result()
  def set_layout(state, diff_buffer, layout)
      when is_pid(diff_buffer) and layout in [:unified, :side_by_side] do
    with {:ok, view} <- fetch_view(state, diff_buffer),
         :ok <- supported_layout(state, layout),
         {:ok, cursor} <- diff_cursor(diff_buffer) do
      width = pane_width(state)

      if view.view_mode == layout and (layout == :unified or view.pane_width == width) do
        {:ok, state}
      else
        {projected, text} = View.reproject(view, layout, width)
        cursor = View.reproject_cursor(view, projected, cursor)
        replace_buffer(state, diff_buffer, projected, text, cursor)
      end
    end
  end

  @doc """
  Returns the exact target at the diff buffer's cursor, or nil for non-views.

  A stale source returns the origin and snapshots but no actionable hunk.
  Pass the active diff buffer to inspect the currently rendered cursor.
  """
  @spec target(state(), pid() | nil) :: target_result()
  def target(state, diff_buffer) do
    with {:ok, view} <- fetch_view(state, diff_buffer),
         {:ok, {row, _col}} <- diff_cursor(diff_buffer) do
      if source_current?(view) do
        {:ok, View.target(view, row)}
      else
        {:error, {:stale_source, View.target(view, nil)}}
      end
    else
      {:error, _reason} -> nil
    end
  end

  @doc "Moves the view's cursor to the next or previous changed region without wrapping."
  @spec navigate(state(), pid(), :next | :previous) :: change_result()
  def navigate(state, diff_buffer, direction)
      when is_pid(diff_buffer) and direction in [:next, :previous] do
    with {:ok, view} <- fetch_view(state, diff_buffer),
         {:ok, {row, _col}} <- diff_cursor(diff_buffer) do
      case View.destination(view, row, direction) do
        nil -> {:error, :no_hunk}
        destination -> move_cursor(state, diff_buffer, destination)
      end
    end
  end

  @doc false
  @spec refresh_saved(state(), pid()) :: state()
  def refresh_saved(state, saved_buffer) when is_pid(saved_buffer) do
    views =
      state.git
      |> GitState.diff_views_for_source(saved_buffer)
      |> Enum.filter(fn {_buffer, view} -> match?(%{contents: _, section: :unstaged}, view) end)

    refresh_views(state, views, saved_buffer)
  end

  @spec refresh_views(state(), [{pid(), View.t()}], pid()) :: state()
  defp refresh_views(state, [], _saved_buffer), do: state

  defp refresh_views(state, views, saved_buffer) do
    case source_text(saved_buffer) do
      {:ok, path, text, version} ->
        Enum.reduce(views, state, fn {diff_buffer, view}, state ->
          refresh_view(state, diff_buffer, view, path, text, version)
        end)

      {:error, :stale_source} ->
        state
    end
  end

  @spec refresh_view(state(), pid(), View.t(), String.t(), String.t(), non_neg_integer()) ::
          state()
  defp refresh_view(state, diff_buffer, view, path, text, version) do
    origin = View.origin(view)
    {base, _old_text} = view.contents

    with :ok <- match_source_path(origin, path),
         {:ok, cursor} <- diff_cursor(diff_buffer),
         {:ok, state} <-
           replace_snapshot(state, diff_buffer, view, origin, {base, text}, version, cursor) do
      state
    else
      {:error, _reason} -> state
    end
  end

  @spec replace_snapshot(
          state(),
          pid(),
          View.t(),
          Origin.t(),
          Target.contents(),
          non_neg_integer() | nil,
          cursor()
        ) :: change_result()
  defp replace_snapshot(state, diff_buffer, view, origin, contents, version, cursor) do
    width = pane_width(state)

    if view.section == origin.section and view.contents == contents and
         (view.view_mode == :unified or view.pane_width == width) do
      if view.source_version == version do
        {:ok, state}
      else
        {:ok, put_view(state, diff_buffer, %{view | source_version: version})}
      end
    else
      {updated, text} = View.build(origin, contents, version, view.view_mode, width)

      if view.section == origin.section do
        replace_buffer(state, diff_buffer, updated, text, cursor)
      else
        switch_section(state, diff_buffer, updated, text, cursor)
      end
    end
  end

  @spec switch_section(state(), pid(), View.t(), String.t(), cursor()) :: change_result()
  defp switch_section(state, old_buffer, view, text, cursor) do
    # Generated buffer titles are fixed at creation. Install the replacement
    # before closing the old view, so a failed open leaves that view intact.
    with {:ok, installed} <- open_buffer(state, view, text, cursor) do
      stop_buffer(old_buffer)
      {:ok, BufferRegistry.retire_dead_buffer(installed, old_buffer)}
    end
  end

  @spec open_buffer(state(), View.t(), String.t(), cursor() | nil) :: change_result()
  defp open_buffer(state, view, text, cursor) do
    filename = Path.basename(view.rel_path)
    theme = state.appearance.theme

    with {:ok, diff_buffer} <-
           Buffer.start_link(
             content: text,
             buffer_type: :nofile,
             read_only: true,
             buffer_name: "#{filename} [diff:#{view.section}]",
             filetype: Language.detect_filetype(filename),
             options_server: state.interaction.options_server
           ) do
      :ok =
        Buffer.batch_decorations(diff_buffer, &Decoration.apply(&1, view.line_metadata, theme))

      if cursor, do: Buffer.move_to(diff_buffer, cursor)

      updated =
        state
        |> put_view(diff_buffer, view)
        |> BufferRegistry.add_buffer(diff_buffer)

      {:ok, updated}
    end
  end

  @spec replace_buffer(state(), pid(), View.t(), String.t(), cursor()) :: change_result()
  defp replace_buffer(state, diff_buffer, view, text, cursor) do
    theme = state.appearance.theme

    :ok =
      Buffer.replace_content_with_decorations(
        diff_buffer,
        text,
        fn decs ->
          Decorations.batch(decs, &Decoration.apply(&1, view.line_metadata, theme))
        end,
        cursor: cursor
      )

    {:ok, put_view(state, diff_buffer, view)}
  catch
    :exit, {:noproc, _call} -> {:error, :closed_diff_view}
    :exit, {:normal, _call} -> {:error, :closed_diff_view}
    :exit, {:shutdown, _call} -> {:error, :closed_diff_view}
  end

  @spec put_view(state(), pid(), View.t()) :: state()
  defp put_view(state, diff_buffer, view),
    do: %{state | git: GitState.register_diff_view(state.git, diff_buffer, view)}

  @spec fetch_view(state(), pid() | nil) :: {:ok, View.t()} | {:error, :not_diff_view}
  defp fetch_view(state, diff_buffer) do
    case GitState.diff_view_info(state.git, diff_buffer) do
      %{contents: _} = view -> {:ok, view}
      _not_a_semantic_diff -> {:error, :not_diff_view}
    end
  end

  @spec admit_source(Origin.t(), binary() | nil) ::
          {:ok, non_neg_integer() | nil} | {:error, :stale_source}
  defp admit_source(%Origin{source_buffer: nil}, _current), do: {:ok, nil}

  defp admit_source(%Origin{source_buffer: source, section: :staged} = origin, _current) do
    with {:ok, path, _version} <- source_identity(source),
         :ok <- match_source_path(origin, path) do
      {:ok, nil}
    end
  end

  defp admit_source(%Origin{source_buffer: source} = origin, current) do
    with {:ok, path, ^current, version} <- source_text(source),
         :ok <- match_source_path(origin, path) do
      {:ok, version}
    else
      _stale -> {:error, :stale_source}
    end
  end

  @spec source_current?(View.t()) :: boolean()
  defp source_current?(%{source_buf: nil}), do: true

  defp source_current?(%{source_buf: source, source_version: expected} = view) do
    case source_identity(source) do
      {:ok, path, version} when is_nil(expected) or version == expected ->
        match_source_path(View.origin(view), path) == :ok

      _stale ->
        false
    end
  end

  @spec match_source_path(Origin.t(), String.t()) :: :ok | {:error, :stale_source}
  defp match_source_path(%Origin{} = origin, path) do
    # The origin names the captured target, even if that path now leads elsewhere.
    expected = Path.expand(origin.rel_path, origin.git_root)

    if Git.Metadata.file_target(path) == expected,
      do: :ok,
      else: {:error, :stale_source}
  end

  @spec source_identity(pid()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :stale_source}
  defp source_identity(source) do
    case Buffer.cursor_context(source) do
      %{file_path: path, version: version} when is_binary(path) -> {:ok, path, version}
      %{file_path: nil} -> {:error, :stale_source}
    end
  catch
    :exit, _reason -> {:error, :stale_source}
  end

  @spec source_text(pid()) ::
          {:ok, String.t(), String.t(), non_neg_integer()} | {:error, :stale_source}
  defp source_text(source) do
    {text, version} = Buffer.content_with_version(source)

    case source_identity(source) do
      {:ok, path, ^version} -> {:ok, path, text, version}
      _stale -> {:error, :stale_source}
    end
  catch
    :exit, _reason -> {:error, :stale_source}
  end

  @spec diff_cursor(pid()) :: {:ok, cursor()} | {:error, :closed_diff_view}
  defp diff_cursor(diff_buffer) do
    {:ok, Buffer.cursor(diff_buffer)}
  catch
    :exit, _reason -> {:error, :closed_diff_view}
  end

  @spec move_cursor(state(), pid(), non_neg_integer()) :: change_result()
  defp move_cursor(state, diff_buffer, row) do
    :ok = Buffer.move_to(diff_buffer, {row, 0})
    {:ok, state}
  catch
    :exit, _reason -> {:error, :closed_diff_view}
  end

  @spec stop_buffer(pid()) :: :ok
  defp stop_buffer(buffer) do
    GenServer.stop(buffer, :normal)
  catch
    :exit, reason when reason in [:noproc, :normal, :shutdown] -> :ok
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  @spec supported_layout(state(), Target.layout()) :: :ok | {:error, :unsupported_layout}
  defp supported_layout(_state, :unified), do: :ok

  defp supported_layout(state, :side_by_side) do
    if Frontend.gui?(state.frontend.capabilities), do: :ok, else: {:error, :unsupported_layout}
  end

  @spec pane_width(state()) :: pos_integer()
  defp pane_width(%{frontend: %{terminal_viewport: %{cols: cols}}}) when cols > 20,
    do: max(div(cols - 5, 2), 20)

  defp pane_width(_state), do: 80
end
