defmodule MingaEditor.Agent.View.Preview do
  @moduledoc """
  Preview pane state machine for the agentic view.

  The right pane of the agentic view reacts to agent tool activity. This
  module manages a discriminated union of content types:

  - `:empty` - no content yet (welcome state)
  - `{:shell, command, output, status}` - shell command output (streaming or done)
  - `{:diff, DiffReview.t()}` - unified diff from a file edit
  - `{:file, path, content}` - file content from a read_file tool

  ToolStart sets a loading state, ToolUpdate streams partial output, and ToolEnd finalizes it. File changes refresh only the selected file or diff; explicit review navigation selects another file.

  Scroll state is tracked here so each content type preserves its own scroll position. A background file change never resets the selected preview's reading position.
  """

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias Minga.Editing.Scroll

  @typedoc "Shell command execution status."
  @type shell_status :: :running | :done | :error

  @typedoc "The content currently displayed in the preview pane."
  @type content ::
          :empty
          | {:shell, command :: String.t(), output :: String.t(), shell_status()}
          | {:diff, DiffReview.t()}
          | {:file, path :: String.t(), content :: String.t()}
          | {:directory, path :: String.t(), entries :: [String.t()]}

  @typedoc "Exact row-producing diff identity, independent of navigation and freshness."
  @type review_source :: {:diff, String.t(), non_neg_integer(), non_neg_integer()}

  @typedoc "Preview pane state."
  @type t :: %__MODULE__{
          content: content(),
          scroll: Scroll.t(),
          freshness: :current | :stale,
          content_revision: non_neg_integer(),
          rows_revision: non_neg_integer(),
          selection_revision: non_neg_integer()
        }

  defstruct content: :empty,
            scroll: %Scroll{},
            freshness: :current,
            content_revision: 0,
            rows_revision: 0,
            selection_revision: 0

  @doc "Creates a new empty preview state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Content transitions ─────────────────────────────────────────────────────

  @doc "Follows tool activity unless an explicitly selected review owns the preview."
  @spec follow_tool_activity(t(), (t() -> t())) :: t()
  def follow_tool_activity(%__MODULE__{content: {:diff, _review}} = preview, transition)
      when is_function(transition, 1),
      do: preview

  def follow_tool_activity(%__MODULE__{} = preview, transition) when is_function(transition, 1),
    do: transition.(preview)

  @doc "Sets the preview to show shell command output (streaming)."
  @spec set_shell(t(), String.t()) :: t()
  def set_shell(%__MODULE__{} = preview, command) do
    commit_content(preview, {:shell, command, "", :running}, Minga.Editing.new_scroll())
  end

  @doc "Updates the shell output with new partial content."
  @spec update_shell_output(t(), String.t()) :: t()
  def update_shell_output(
        %__MODULE__{content: {:shell, cmd, _old_output, :running}} = preview,
        new_output
      ) do
    commit_content(preview, {:shell, cmd, new_output, :running}, preview.scroll)
  end

  def update_shell_output(%__MODULE__{} = preview, _output), do: preview

  @doc "Marks the shell command as complete."
  @spec finish_shell(t(), String.t(), shell_status()) :: t()
  def finish_shell(
        %__MODULE__{content: {:shell, cmd, _old, :running}} = preview,
        final_output,
        status
      )
      when status in [:done, :error] do
    commit_content(preview, {:shell, cmd, final_output, status}, preview.scroll)
  end

  def finish_shell(%__MODULE__{} = preview, _output, _status), do: preview

  @doc "Sets the preview to show a diff review."
  @spec set_diff(t(), DiffReview.t()) :: t()
  def set_diff(%__MODULE__{} = preview, %DiffReview{} = review) do
    commit_content(preview, {:diff, review}, Scroll.new(0))
  end

  @doc "Replaces the current diff review, preserving scroll while a diff remains."
  @spec replace_diff(t(), DiffReview.t() | nil) :: t()
  def replace_diff(%__MODULE__{} = preview, %DiffReview{} = review) do
    commit_content(preview, {:diff, review}, preview.scroll)
  end

  def replace_diff(%__MODULE__{} = preview, nil), do: clear(preview)

  @doc """
  Invalidates a selected file's revision without moving its reading anchor.

  The current preview has no source-bound reading anchor, so an integer offset cannot safely follow inserted or removed rows. Keep the exact last-good presentation and disable decisions until explicit Review acquires the current cumulative revision. Unrelated writes leave every field unchanged.
  """
  @spec refresh_after_write(t(), String.t(), String.t(), EditTimeline.t()) :: t()
  def refresh_after_write(
        %__MODULE__{content: {:diff, %DiffReview{path: path}}} = preview,
        path,
        _after_content,
        _timeline
      ),
      do: %{preview | freshness: :stale}

  def refresh_after_write(
        %__MODULE__{content: {:file, path, _content}} = preview,
        path,
        _after_content,
        _timeline
      ),
      do: %{preview | freshness: :stale}

  def refresh_after_write(%__MODULE__{} = preview, _path, _after_content, _timeline),
    do: preview

  @doc "Updates the diff review within the preview."
  @spec update_diff(t(), (DiffReview.t() -> DiffReview.t())) :: t()
  def update_diff(%__MODULE__{content: {:diff, review}, freshness: :current} = preview, fun)
      when is_function(fun, 1) do
    commit_content(preview, {:diff, fun.(review)}, preview.scroll)
  end

  def update_diff(%__MODULE__{} = preview, _fun), do: preview

  @doc "Moves the actionable hunk without invalidating resident review rows."
  @spec navigate_hunk(t(), :next | :previous) :: t()
  def navigate_hunk(%__MODULE__{content: {:diff, review}, freshness: :current} = preview, :next) do
    commit_navigation(preview, DiffReview.next_hunk(review))
  end

  def navigate_hunk(
        %__MODULE__{content: {:diff, review}, freshness: :current} = preview,
        :previous
      ) do
    commit_navigation(preview, DiffReview.prev_hunk(review))
  end

  def navigate_hunk(%__MODULE__{} = preview, direction) when direction in [:next, :previous],
    do: preview

  @doc "Returns the identity of current or frozen resident review rows."
  @spec review_source(t()) :: review_source() | nil
  def review_source(%__MODULE__{content: {:diff, %DiffReview{path: path}}} = preview),
    do: {:diff, path, preview.rows_revision, preview.selection_revision}

  def review_source(%__MODULE__{}), do: nil

  @doc "Observes matching row geometry without changing reading intent or decision freshness."
  @spec observe_review(t(), review_source(), non_neg_integer(), pos_integer()) ::
          {:ok, t()} | :stale
  def observe_review(
        %__MODULE__{
          content: {:diff, %DiffReview{path: path}},
          rows_revision: rows,
          selection_revision: selection
        } = preview,
        {:diff, path, rows, selection},
        total_rows,
        visible_rows
      )
      when is_integer(total_rows) and total_rows >= 0 and is_integer(visible_rows) and
             visible_rows > 0 do
    {:ok, %{preview | scroll: Scroll.update_metrics(preview.scroll, total_rows, visible_rows)}}
  end

  def observe_review(%__MODULE__{}, _source, total_rows, visible_rows)
      when is_integer(total_rows) and total_rows >= 0 and is_integer(visible_rows) and
             visible_rows > 0,
      do: :stale

  @doc "Returns a current actionable DiffReview, never the stale last-good presentation."
  @spec diff_review(t()) :: DiffReview.t() | nil
  def diff_review(%__MODULE__{content: {:diff, review}, freshness: :current}), do: review
  def diff_review(%__MODULE__{}), do: nil

  @doc "Returns the explicitly selected file, never a newly arrived change."
  @spec selected_path(t()) :: String.t() | nil
  def selected_path(%__MODULE__{content: {:diff, %DiffReview{path: path}}}), do: path
  def selected_path(%__MODULE__{content: {:file, path, _content}}), do: path
  def selected_path(%__MODULE__{}), do: nil

  @doc "Sets the preview to show file content."
  @spec set_file(t(), String.t(), String.t()) :: t()
  def set_file(%__MODULE__{} = preview, path, content) do
    commit_content(preview, {:file, path, content}, Scroll.new(0))
  end

  @doc "Sets the preview to show a directory listing."
  @spec set_directory(t(), String.t(), [String.t()]) :: t()
  def set_directory(%__MODULE__{} = preview, path, entries) when is_list(entries) do
    commit_content(preview, {:directory, path, entries}, Scroll.new(0))
  end

  @doc "Clears the preview to empty state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = preview) do
    commit_content(preview, :empty, Minga.Editing.new_scroll())
  end

  @doc "Scrolls a retained review to an admitted display row without changing its source."
  @spec scroll_to_row(t(), non_neg_integer()) :: t()
  def scroll_to_row(%__MODULE__{scroll: scroll} = preview, row)
      when is_integer(row) and row >= 0 do
    bottom = max(scroll.metrics.total_lines - scroll.metrics.visible_height, 0)
    %{preview | scroll: Minga.Editing.Scroll.set_offset(scroll, min(row, bottom))}
  end

  # ── Scrolling (delegates to Minga.Editing.Scroll) ──────────────────────────────────

  @doc "Scrolls down. Delegates to `Minga.Editing.scroll_down/2`."
  @spec scroll_down(t(), pos_integer()) :: t()
  def scroll_down(%__MODULE__{} = preview, amount) do
    %{preview | scroll: Minga.Editing.scroll_down(preview.scroll, amount)}
  end

  @doc "Scrolls up. Delegates to `Minga.Editing.scroll_up/2`."
  @spec scroll_up(t(), pos_integer()) :: t()
  def scroll_up(%__MODULE__{} = preview, amount) do
    %{preview | scroll: Minga.Editing.scroll_up(preview.scroll, amount)}
  end

  @doc "Scrolls to top. Delegates to `Minga.Editing.scroll_to_top/1`."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = preview) do
    %{preview | scroll: Minga.Editing.scroll_to_top(preview.scroll)}
  end

  @doc "Pins to bottom. Delegates to `Minga.Editing.pin_to_bottom/1`."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = preview) do
    %{preview | scroll: Minga.Editing.pin_to_bottom(preview.scroll)}
  end

  @spec commit_content(t(), content(), Scroll.t()) :: t()
  defp commit_content(preview, content, scroll) do
    %{
      preview
      | content: content,
        scroll: scroll,
        freshness: :current,
        content_revision: preview.content_revision + 1,
        rows_revision: preview.rows_revision + 1,
        selection_revision:
          advance_selection(
            preview.selection_revision,
            selection_identity(preview.content),
            selection_identity(content)
          )
    }
  end

  @spec commit_navigation(t(), DiffReview.t()) :: t()
  defp commit_navigation(preview, review) do
    %{preview | content: {:diff, review}, content_revision: preview.content_revision + 1}
  end

  @spec selection_identity(content()) :: term()
  defp selection_identity(:empty), do: :empty
  defp selection_identity({:diff, %DiffReview{path: path}}), do: {:diff, path}
  defp selection_identity({:file, path, _content}), do: {:file, path}
  defp selection_identity({:directory, path, _entries}), do: {:directory, path}
  defp selection_identity({:shell, command, _output, _status}), do: {:shell, command}

  @spec advance_selection(non_neg_integer(), term(), term()) :: non_neg_integer()
  defp advance_selection(revision, selection, selection), do: revision
  defp advance_selection(revision, _previous, _current), do: revision + 1

  # ── Queries ─────────────────────────────────────────────────────────────────

  @doc "Returns true if the preview is empty."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{content: :empty}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Returns true if the preview is showing a diff review."
  @spec diff?(t()) :: boolean()
  def diff?(%__MODULE__{content: {:diff, _}}), do: true
  def diff?(%__MODULE__{}), do: false

  @doc "Returns true if the preview is showing shell output."
  @spec shell?(t()) :: boolean()
  def shell?(%__MODULE__{content: {:shell, _, _, _}}), do: true
  def shell?(%__MODULE__{}), do: false

  @doc "Returns true if the preview is showing a directory listing."
  @spec directory?(t()) :: boolean()
  def directory?(%__MODULE__{content: {:directory, _, _}}), do: true
  def directory?(%__MODULE__{}), do: false
end
