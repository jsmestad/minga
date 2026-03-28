defmodule Minga.Input.Handler do
  @moduledoc """
  Behaviour for key input handlers in the focus stack.

  Each handler module decides whether to consume a key press or pass it
  through to the next handler in the stack. Handlers self-gate: they
  return `{:passthrough, state}` when their feature is inactive (e.g.,
  the picker handler passes through when no picker is open).

  ## State contract

  Input handlers receive a `handler_state()` which is currently
  `Editor.State.t()`. This type alias is the narrowing point: as the
  shell independence refactor progresses, it will be replaced by a
  focused contract struct containing only what handlers need (workspace,
  capabilities, layout, shell_state). Handlers should avoid accessing
  fields outside these four to prepare for that narrowing.

  ## Implementing a handler

      defmodule MyHandler do
        @behaviour Minga.Input.Handler

        @impl true
        def handle_key(state, _codepoint, _modifiers) do
          if my_feature_active?(state) do
            {:handled, do_something(state)}
          else
            {:passthrough, state}
          end
        end
      end
  """

  alias Minga.Editor.State, as: EditorState

  @typedoc """
  The state type passed to input handlers.

  Currently `Editor.State.t()`. This alias is the single point to narrow
  when the input contract is fully decoupled from `Editor.State`. Handlers
  should access only: `workspace`, `capabilities`, `layout`, `shell_state`.
  """
  @type handler_state :: EditorState.t()

  @typedoc "Result of handling a key press."
  @type result :: {:handled, handler_state()} | {:passthrough, handler_state()}

  @doc """
  Processes a key press event.

  Returns `{:handled, state}` if this handler consumed the key, or
  `{:passthrough, state}` if the key should be forwarded to the next
  handler in the stack. The handler may modify state even when passing
  through (e.g., clearing a transient flag).
  """
  @callback handle_key(
              handler_state(),
              codepoint :: non_neg_integer(),
              modifiers :: non_neg_integer()
            ) :: result()

  @doc """
  Processes a mouse event.

  Returns `{:handled, state}` if this handler consumed the mouse event,
  or `{:passthrough, state}` to forward it to the next handler.

  The default implementation passes through all mouse events. Override
  this callback to intercept mouse events for your UI region.
  """
  @callback handle_mouse(
              handler_state(),
              row :: integer(),
              col :: integer(),
              button :: atom(),
              modifiers :: non_neg_integer(),
              event_type :: atom(),
              click_count :: pos_integer()
            ) :: result()

  @optional_callbacks [handle_mouse: 7]
end
