defmodule Minga.Agent.UIState.Panel do
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

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Scroll

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
          mention_completion: Minga.Agent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()],
          cached_line_index: [{non_neg_integer(), Minga.Agent.BufferSync.line_type()}],
          cached_styled_messages: [Minga.Agent.MarkdownHighlight.styled_lines()] | nil
        }

  @enforce_keys []
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
            cached_styled_messages: nil

  @doc "Creates a new panel state with defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Buffer readers ──────────────────────────────────────────────────────

  @doc "Returns the input lines as a list of strings."
  @spec input_lines(t()) :: [String.t()]
  def input_lines(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid) |> String.split("\n")
  end

  def input_lines(%__MODULE__{}), do: [""]

  @doc "Returns the input cursor position as `{line, col}`."
  @spec input_cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.cursor(pid)
  end

  def input_cursor(%__MODULE__{}), do: {0, 0}

  @doc "Returns the number of input lines."
  @spec input_line_count(t()) :: pos_integer()
  def input_line_count(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.line_count(pid)
  end

  def input_line_count(%__MODULE__{}), do: 1

  @doc "Returns true if the input is empty (single empty line)."
  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid) == ""
  end

  def input_empty?(%__MODULE__{}), do: true

  @doc "Returns the raw input text (with placeholders, not substituted)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid)
  end

  def input_text(%__MODULE__{}), do: ""
end
