defmodule Minga.Agent.View.Preview do
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

  alias Minga.Agent.DiffReview

  @typedoc "Shell command execution status."
  @type shell_status :: :running | :done | :error

  @typedoc "The content currently displayed in the preview pane."
  @type content ::
          :empty
          | {:shell, command :: String.t(), output :: String.t(), shell_status()}
          | {:diff, DiffReview.t()}
          | {:file, path :: String.t(), content :: String.t()}

  @typedoc "Preview pane state."
  @type t :: %__MODULE__{
          content: content(),
          scroll_offset: non_neg_integer(),
          auto_follow: boolean()
        }

  @enforce_keys []
  defstruct content: :empty,
            scroll_offset: 0,
            auto_follow: true

  @doc "Creates a new empty preview state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Content transitions ─────────────────────────────────────────────────────

  @doc "Sets the preview to show shell command output (streaming)."
  @spec set_shell(t(), String.t()) :: t()
  def set_shell(%__MODULE__{} = preview, command) do
    %{preview | content: {:shell, command, "", :running}, scroll_offset: 0, auto_follow: true}
  end

  @doc "Updates the shell output with new partial content."
  @spec update_shell_output(t(), String.t()) :: t()
  def update_shell_output(
        %__MODULE__{content: {:shell, cmd, _old_output, :running}} = preview,
        new_output
      ) do
    preview = %{preview | content: {:shell, cmd, new_output, :running}}
    maybe_auto_scroll_preview(preview)
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
    preview = %{preview | content: {:shell, cmd, final_output, status}}
    maybe_auto_scroll_preview(preview)
  end

  def finish_shell(%__MODULE__{} = preview, _output, _status), do: preview

  @doc "Sets the preview to show a diff review."
  @spec set_diff(t(), DiffReview.t()) :: t()
  def set_diff(%__MODULE__{} = preview, %DiffReview{} = review) do
    %{preview | content: {:diff, review}, scroll_offset: 0, auto_follow: true}
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
    %{preview | content: {:file, path, content}, scroll_offset: 0, auto_follow: true}
  end

  @doc "Clears the preview to empty state."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = preview) do
    %{preview | content: :empty, scroll_offset: 0, auto_follow: true}
  end

  # ── Scrolling ───────────────────────────────────────────────────────────────

  @doc "Scrolls down by the given amount. Disengages auto-follow."
  @spec scroll_down(t(), pos_integer()) :: t()
  def scroll_down(%__MODULE__{} = preview, amount) do
    %{preview | scroll_offset: preview.scroll_offset + amount, auto_follow: false}
  end

  @doc "Scrolls up by the given amount (clamped at 0). Disengages auto-follow."
  @spec scroll_up(t(), pos_integer()) :: t()
  def scroll_up(%__MODULE__{} = preview, amount) do
    %{preview | scroll_offset: max(preview.scroll_offset - amount, 0), auto_follow: false}
  end

  @doc "Scrolls to the top. Disengages auto-follow."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = preview) do
    %{preview | scroll_offset: 0, auto_follow: false}
  end

  @doc "Scrolls to the bottom. Re-engages auto-follow."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = preview) do
    %{preview | scroll_offset: 999_999, auto_follow: true}
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

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec maybe_auto_scroll_preview(t()) :: t()
  defp maybe_auto_scroll_preview(%__MODULE__{auto_follow: true} = preview) do
    %{preview | scroll_offset: 999_999}
  end

  defp maybe_auto_scroll_preview(%__MODULE__{} = preview), do: preview
end
