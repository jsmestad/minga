defmodule MingaEditor.Agent.View.Preview do
  @moduledoc """
  Preview pane state machine for the agentic view.

  The right pane of the agentic view reacts to agent tool activity. This
  module manages a discriminated union of content types:

  - `:empty` - no content yet (welcome state)
  - `{:shell, command, output, status}` - shell command output (streaming or done)
  - `{:diff, DiffReview.t()}` - unified diff from a file edit
  - `{:file, path, content}` - file content from a read_file tool

  The preview updates in response to tool events: ToolStart sets a loading
  state, ToolUpdate streams partial output, ToolEnd finalizes, and
  ToolFileChanged triggers diff mode.

  Scroll state is tracked here so each content type preserves its own scroll
  position. Auto-follow pauses when the user scrolls manually and resumes on
  the next tool event.
  """

  alias MingaEditor.Agent.DiffReview
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

  @typedoc "Preview pane state."
  @type t :: %__MODULE__{
          content: content(),
          scroll: Scroll.t()
        }

  defstruct content: :empty,
            scroll: %Scroll{}

  @doc "Creates a new empty preview state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Content transitions ─────────────────────────────────────────────────────

  @doc "Sets the preview to show shell command output (streaming)."
  @spec set_shell(t(), String.t()) :: t()
  def set_shell(%__MODULE__{} = preview, command) do
    %{preview | content: {:shell, command, "", :running}, scroll: Minga.Editing.new_scroll()}
  end

  @doc "Updates the shell output with new partial content."
  @spec update_shell_output(t(), String.t()) :: t()
  def update_shell_output(
        %__MODULE__{content: {:shell, cmd, _old_output, :running}} = preview,
        new_output
      ) do
    %{preview | content: {:shell, cmd, new_output, :running}}
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
    %{preview | content: {:shell, cmd, final_output, status}}
  end

  def finish_shell(%__MODULE__{} = preview, _output, _status), do: preview

  @doc "Sets the preview to show a diff review."
  @spec set_diff(t(), DiffReview.t()) :: t()
  def set_diff(%__MODULE__{} = preview, %DiffReview{} = review) do
    %{preview | content: {:diff, review}, scroll: Minga.Editing.new_scroll()}
  end

  @doc "Updates the diff review within the preview."
  @spec update_diff(t(), (DiffReview.t() -> DiffReview.t())) :: t()
  def update_diff(%__MODULE__{content: {:diff, review}} = preview, fun)
      when is_function(fun, 1) do
    %{preview | content: {:diff, fun.(review)}}
  end

  def update_diff(%__MODULE__{} = preview, _fun), do: preview

  @doc "Returns the DiffReview if the preview is in diff mode, nil otherwise."
  @spec diff_review(t()) :: DiffReview.t() | nil
  def diff_review(%__MODULE__{content: {:diff, review}}), do: review
  def diff_review(%__MODULE__{}), do: nil

  @doc "Sets the preview to show file content."
  @spec set_file(t(), String.t(), String.t()) :: t()
  def set_file(%__MODULE__{} = preview, path, content) do
    %{preview | content: {:file, path, content}, scroll: Minga.Editing.new_scroll()}
  end

  @doc "Sets the preview to show a directory listing."
  @spec set_directory(t(), String.t(), [String.t()]) :: t()
  def set_directory(%__MODULE__{} = preview, path, entries) when is_list(entries) do
    %{preview | content: {:directory, path, entries}, scroll: Minga.Editing.new_scroll()}
  end

  @doc "Clears the preview to empty state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = preview) do
    %{preview | content: :empty, scroll: Minga.Editing.new_scroll()}
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
