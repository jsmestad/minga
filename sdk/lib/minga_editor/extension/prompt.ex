defmodule MingaEditor.Extension.Prompt do
  @moduledoc """
  Opens source-owned prompts in the editor minibuffer from an extension callback.

  Return the editor state from a successful opening to display the prompt.
  The host dismisses the prompt before calling `MingaEditor.Extension.Prompt.Handler`
  with the original `args`. Replacing a prompt or unloading its owner discards it
  without calling its handler.

  The SDK declares the API for compilation; the editor provides the runtime.
  """

  alias MingaEditor.Extension.EditorAPI

  @type admission :: :replace | :if_idle
  @type decision :: :accepted | :canceled
  @type option :: {:label, String.t()} | {:admission, admission()}
  @type text_option :: option() | {:default, String.t()}
  @type error ::
          :modal_busy
          | :not_extension_callback
          | :source_unavailable
          | :invalid_handler
          | :unsupported_shell
  @type result :: {:ok, EditorAPI.state()} | {:error, error()}

  @doc """
  Opens a text prompt. `:label` is required; `:default` is initially empty.

  Admission defaults to `:replace`. Use `admission: :if_idle` to preserve an active
  modal and receive `{:error, :modal_busy}` instead. Quit and conflict prompts
  are never replaced.
  """
  @spec text(EditorAPI.state(), module(), term(), [text_option()]) :: result()
  def text(_state, _handler, _args, _opts), do: raise("minga_sdk is compile-time only")

  @doc """
  Opens a Yes/No prompt with the required `:label` and the same admission policy as `text/4`.

  `y` or Yes accepts; `n`, Escape, or No cancels. No other key or paste chooses an answer.
  """
  @spec confirm(EditorAPI.state(), module(), term(), [option()]) :: result()
  def confirm(_state, _handler, _args, _opts), do: raise("minga_sdk is compile-time only")
end
