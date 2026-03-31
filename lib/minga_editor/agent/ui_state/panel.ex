defmodule MingaEditor.Agent.UIState.Panel do
  @moduledoc """
  Prompt editing and chat display state.

  Holds the data for the agent prompt (buffer, history, cursor, paste blocks)
  and chat display (scroll, spinner, model config, display offset). This is
  the "panel" half of the agent UI, separated from layout/search/preview
  concerns in `UIState.View`.

  Most callers interact through `UIState` functions rather than accessing
  this struct directly. `AgentAccess.panel/1` returns this struct for
  read-only field access in input handlers and renderers.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias Minga.Buffer
  alias Minga.Editing.Scroll

  @typedoc "A collapsed paste block. Stores the original text and whether the block is currently expanded for editing."
  @type paste_block :: %{text: String.t(), expanded: boolean()}

  @typedoc "Prompt editing and chat display state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll: Scroll.t(),
          prompt_buffer: pid() | nil,
          prompt_history: [String.t()],
          history_index: integer(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          model_name: String.t(),
          thinking_level: String.t(),
          input_focused: boolean(),
          display_start_index: non_neg_integer(),
          mention_completion: MingaAgent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()],
          cached_line_index: [{non_neg_integer(), MingaEditor.Agent.BufferSync.line_type()}],
          cached_styled_messages: [MingaEditor.Agent.MarkdownHighlight.styled_lines()] | nil,
          message_version: non_neg_integer()
        }

  defstruct visible: false,
            scroll: %Scroll{},
            prompt_buffer: nil,
            prompt_history: [],
            history_index: -1,
            spinner_frame: 0,
            provider_name: "anthropic",
            model_name: AgentConfig.default_model(),
            thinking_level: "medium",
            input_focused: false,
            display_start_index: 0,
            mention_completion: nil,
            pasted_blocks: [],
            cached_line_index: [],
            cached_styled_messages: nil,
            message_version: 0

  @doc "Creates a new panel state with defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Buffer readers ──────────────────────────────────────────────────────

  @doc "Returns the input lines as a list of strings."
  @spec input_lines(t()) :: [String.t()]
  def input_lines(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid) |> String.split("\n")
  end

  def input_lines(%__MODULE__{}), do: [""]

  @doc "Returns the input cursor position as `{line, col}`."
  @spec input_cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.cursor(pid)
  end

  def input_cursor(%__MODULE__{}), do: {0, 0}

  @doc "Returns the number of input lines."
  @spec input_line_count(t()) :: pos_integer()
  def input_line_count(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.line_count(pid)
  end

  def input_line_count(%__MODULE__{}), do: 1

  @doc "Returns true if the input is empty (single empty line)."
  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid) == ""
  end

  def input_empty?(%__MODULE__{}), do: true

  @doc "Returns the raw input text (with placeholders, not substituted)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    Buffer.content(pid)
  end

  def input_text(%__MODULE__{}), do: ""

  @doc "Increments the message version counter. Used to invalidate the GUI fingerprint cache when message content changes (collapse toggles, new messages, etc.)."
  @spec bump_message_version(t()) :: t()
  def bump_message_version(%__MODULE__{message_version: v} = panel) do
    %{panel | message_version: v + 1}
  end
end
