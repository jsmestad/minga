defmodule Minga.RenderModel.UI.AgentChat do
  @moduledoc """
  Semantic agent chat model.

  Describes the agent conversation view: visibility, runtime status, the active
  model name and thinking level, the prompt buffer plus its cell-grid metadata
  (cursor, vim mode, line counts), an optional prompt completion popup, an
  optional help overlay, and the list of
  conversation messages with their stable BEAM-assigned IDs.

  This is pure data with domain fields and **core types only**. It does not
  reference any product module; the editor builder pre-resolves every agent
  struct into the core views defined here before putting them on the model. The
  GUI adapter
  (`Minga.Frontend.Adapter.GUI.AgentChatEncoder`) owns the wire encoding. A
  hidden panel is just `%AgentChat{visible?: false}`; the encoder derives a
  change-detection fingerprint with `:erlang.phash2/1`, so no sentinel is needed.

  ## Messages

  `messages` is a list of `{id, body}` tuples where `id` is a stable uint32 the
  GUI uses as a persistent identity. `body` is one of the resolved core message
  forms produced by the editor builder:

    * `{:user, text}` / `{:user, text, attachments}`
    * `{:assistant, text}`
    * `{:styled_assistant, styled_lines}`
    * `{:assistant_markdown, markdown_blocks}`
    * `{:thinking, text, collapsed?}`
    * `{:tool_call, %AgentChat.ToolCallView{}}`
    * `{:styled_tool_call, %AgentChat.ToolCallView{}, styled_lines}`
    * `{:approval_tool_call, %AgentChat.ApprovalView{}}`
    * `{:system, text, level}`
    * `{:usage, %AgentChat.Usage{}}`

  Bare body tuples (without an `id` wrapper) are also accepted and encode with
  ID `0`, matching the historical wire behaviour.

  ## Resident transcript

  `messages` is the windowed, byte-capped tail the legacy `gui_agent_chat` (0x78)
  section carries. `resident_messages` is the full, un-windowed transcript (same
  `message()` shape) that rides the dedicated `gui_agent_transcript` (0x86)
  stream so the frontend can scroll the whole session from local data (#2654).
  `transcript_epoch` is an opaque change token that flips on structural change
  (session switch, display-start/compaction), driving the resident stream's
  full-replace-vs-append decision. Both default empty/zero so surfaces that do
  not populate them keep the historical single-transport behaviour.
  """

  alias __MODULE__.ApprovalView
  alias __MODULE__.MarkdownBlock
  alias __MODULE__.PromptCompletion
  alias __MODULE__.ToolCallView
  alias __MODULE__.Usage

  @typedoc "A styled text run: {text, fg_rgb, bg_rgb, flags} or with a trailing url."
  @type styled_run ::
          {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @typedoc "A conversation message body."
  @type message_body ::
          {:user, String.t()}
          | {:user, String.t(), term()}
          | {:assistant, String.t()}
          | {:styled_assistant, [styled_line()]}
          | {:assistant_markdown, [MarkdownBlock.t()]}
          | {:thinking, String.t(), boolean()}
          | {:tool_call, ToolCallView.t()}
          | {:styled_tool_call, ToolCallView.t(), [styled_line()]}
          | {:approval_tool_call, ApprovalView.t()}
          | {:system, String.t(), atom()}
          | {:usage, Usage.t()}

  @typedoc "A message with its stable GUI identity, or a bare body that encodes with ID 0."
  @type message :: {pos_integer(), message_body()} | message_body()

  @type t :: %__MODULE__{
          visible?: boolean(),
          status: atom(),
          # Chrome fields are typed `| nil` defensively: defstruct defaults are non-nil
          # and the builder always populates them, but the encoder retains `|| default`
          # fallbacks for directly-constructed structs (tests do this), so the types
          # reflect what the encoder actually tolerates rather than builder guarantees.
          model_name: String.t() | nil,
          thinking_level: String.t() | nil,
          prompt: String.t() | nil,
          prompt_line_count: non_neg_integer() | nil,
          prompt_cursor_line: non_neg_integer() | nil,
          prompt_cursor_col: non_neg_integer() | nil,
          prompt_vim_mode: atom() | nil,
          prompt_visible_rows: non_neg_integer() | nil,
          prompt_completion: PromptCompletion.t() | nil,
          help_visible?: boolean(),
          help_groups: [{String.t(), [{String.t(), String.t()}]}],
          messages: [message()],
          resident_messages: [message()],
          transcript_epoch: non_neg_integer()
        }

  defstruct visible?: false,
            status: :idle,
            model_name: "",
            thinking_level: "",
            prompt: "",
            prompt_line_count: 1,
            prompt_cursor_line: 0,
            prompt_cursor_col: 0,
            prompt_vim_mode: nil,
            prompt_visible_rows: 1,
            prompt_completion: nil,
            help_visible?: false,
            help_groups: [],
            messages: [],
            resident_messages: [],
            transcript_epoch: 0

  defmodule PromptCompletion do
    @moduledoc """
    Prompt completion popup state for @-mention or /slash completion.

    `candidates` are either `{name, description}` tuples or bare name strings.
    """

    @type candidate :: {String.t(), String.t()} | String.t()

    @type t :: %__MODULE__{
            type: :mention | :slash,
            candidates: [candidate()],
            selected: non_neg_integer(),
            # nil-tolerated by the GUI encoder's `anchor_line || 0` fallback.
            anchor_line: non_neg_integer() | nil,
            anchor_col: non_neg_integer() | nil
          }

    defstruct type: :mention,
              candidates: [],
              selected: 0,
              anchor_line: 0,
              anchor_col: 0
  end

  defmodule ToolCallView do
    @moduledoc """
    Pre-resolved core view of a tool call message.

    The editor builder converts the agent's tool-call struct into this core view
    so the GUI encoder never touches the agent struct: `summary` is already the
    resolved one-line summary string, `status` is a core atom
    (`:running | :complete | :error`), and `auto_approved_scope` is a core atom
    (`:session | :turn | nil`).
    """

    @typedoc "Resolved tool-call execution status."
    @type status :: :running | :complete | :error

    @typedoc "Resolved scope that auto-approved this tool call."
    @type auto_approved_scope :: :session | :turn | nil

    @typedoc "Resolved preview kind for inline tool-call previews."
    @type preview_kind :: :diff | :command | :target | :args

    @type t :: %__MODULE__{
            name: String.t(),
            summary: String.t(),
            result: String.t(),
            status: status(),
            is_error: boolean(),
            collapsed: boolean(),
            duration_ms: non_neg_integer() | nil,
            auto_approved_scope: auto_approved_scope(),
            preview_kind: preview_kind(),
            preview_lines: [String.t()]
          }

    defstruct name: "",
              summary: "",
              result: "",
              status: :running,
              is_error: false,
              collapsed: true,
              duration_ms: nil,
              auto_approved_scope: nil,
              preview_kind: :args,
              preview_lines: []
  end

  defmodule ApprovalView do
    @moduledoc """
    Pre-resolved core view of an inline approval tool call card.

    The editor builder runs the agent's approval-preview builder (or reads a
    supplied preview), then stores the already-built `summary`, `preview_kind`
    (`:diff | :command | :target | :args`), and `preview_lines` here. The GUI
    encoder serializes these resolved fields without touching any agent struct.
    """

    @typedoc "Resolved preview kind for an approval card."
    @type preview_kind :: :diff | :command | :target | :args

    @type t :: %__MODULE__{
            name: String.t(),
            tool_call_id: String.t(),
            summary: String.t(),
            preview_kind: preview_kind(),
            preview_lines: [String.t()]
          }

    defstruct name: "",
              tool_call_id: "",
              summary: "",
              preview_kind: :args,
              preview_lines: []
  end

  defmodule Usage do
    @moduledoc """
    Pre-resolved core view of a turn-usage message.

    The editor builder copies the numeric fields out of the agent's turn-usage
    struct into this core view so the GUI encoder serializes plain numbers.
    """

    @type t :: %__MODULE__{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_write: non_neg_integer(),
            cost: float()
          }

    defstruct input: 0,
              output: 0,
              cache_read: 0,
              cache_write: 0,
              cost: 0.0
  end
end
