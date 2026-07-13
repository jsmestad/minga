defmodule MingaEditor.Agent.UIState.Presentation do
  @moduledoc """
  Pure lifecycle owner for activation of the full-screen agent presentation.

  Activation records one coherent editor return target and saved layout.
  Completion or cancellation deactivates the presentation and clears every
  activation-local field together, preventing stale return targets or key
  prefixes from leaking into a replacement activation.
  """

  alias MingaEditor.Agent.UIState.ReturnTarget
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows

  @type focus :: :chat | :file_viewer
  @type prefix :: nil | :g | :z | :bracket_next | :bracket_prev | Minga.Keymap.Bindings.Node.t()
  @type t :: %__MODULE__{
          active: boolean(),
          focus: focus(),
          saved_windows: Windows.t() | nil,
          saved_file_tree: FileTreeState.t() | nil,
          return_target: ReturnTarget.t() | nil,
          pending_prefix: prefix()
        }

  defstruct active: false,
            focus: :chat,
            saved_windows: nil,
            saved_file_tree: nil,
            return_target: nil,
            pending_prefix: nil

  @doc "Activates or replaces the presentation's complete return context."
  @spec activate(
          t(),
          Windows.t() | nil,
          FileTreeState.t() | nil,
          ReturnTarget.t() | nil
        ) :: t()
  def activate(%__MODULE__{} = presentation, windows, file_tree, return_target) do
    %{
      presentation
      | active: true,
        focus: :chat,
        saved_windows: windows,
        saved_file_tree: file_tree,
        return_target: return_target,
        pending_prefix: nil
    }
  end

  @doc "Completes presentation use and returns the layout to restore."
  @spec complete(t()) :: {t(), Windows.t() | nil, FileTreeState.t() | nil}
  def complete(%__MODULE__{} = presentation) do
    {reset(presentation), presentation.saved_windows, presentation.saved_file_tree}
  end

  @doc "Cancels presentation use with the same cleanup guarantee as completion."
  @spec cancel(t()) :: {t(), Windows.t() | nil, FileTreeState.t() | nil}
  def cancel(%__MODULE__{} = presentation), do: complete(presentation)

  @doc "Replaces the editor return target for the active presentation."
  @spec replace_return_target(t(), ReturnTarget.t() | nil) :: t()
  def replace_return_target(%__MODULE__{} = presentation, return_target),
    do: %{presentation | return_target: return_target}

  @doc "Switches keyboard focus inside the agent presentation."
  @spec focus(t(), focus()) :: t()
  def focus(%__MODULE__{} = presentation, focus) when focus in [:chat, :file_viewer],
    do: %{presentation | focus: focus}

  @doc "Installs a pending multi-key prefix."
  @spec install_prefix(t(), prefix()) :: t()
  def install_prefix(%__MODULE__{} = presentation, prefix)
      when prefix in [nil, :g, :z, :bracket_next, :bracket_prev] or is_map(prefix),
      do: %{presentation | pending_prefix: prefix}

  @doc "Clears a pending multi-key prefix."
  @spec reset_prefix(t()) :: t()
  def reset_prefix(%__MODULE__{} = presentation),
    do: %{presentation | pending_prefix: nil}

  @doc "Returns whether the agent presentation is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{active: active}), do: active

  @doc "Returns the focused agent panel."
  @spec current_focus(t()) :: focus()
  def current_focus(%__MODULE__{focus: focus}), do: focus

  @doc "Returns the editor return target."
  @spec return_target(t()) :: ReturnTarget.t() | nil
  def return_target(%__MODULE__{return_target: target}), do: target

  @doc "Returns the pending multi-key prefix."
  @spec pending_prefix(t()) :: prefix()
  def pending_prefix(%__MODULE__{pending_prefix: prefix}), do: prefix

  @spec reset(t()) :: t()
  defp reset(%__MODULE__{} = presentation) do
    %{
      presentation
      | active: false,
        focus: :chat,
        saved_windows: nil,
        saved_file_tree: nil,
        return_target: nil,
        pending_prefix: nil
    }
  end
end
