defmodule MingaEditor.Renderer.RenderReceipt do
  @moduledoc """
  Focused Renderer-to-Editor process receipt.

  Receipts contain only editor-owned transition results and frame correlation
  metadata. Resident stores, window render caches, adapter caches, font state,
  acknowledgement leases, and message-store cursors never cross back.
  """

  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.State.Windows

  @enforce_keys [
    :layout,
    :focus_tree,
    :shell_id,
    :shell_identity,
    :modeline_click_regions,
    :tab_bar_click_regions,
    :frame_seq,
    :keyframe?,
    :render_sent_at
  ]
  defstruct [
    :layout,
    :focus_tree,
    :shell_id,
    :shell_identity,
    :modeline_click_regions,
    :tab_bar_click_regions,
    :frame_seq,
    :keyframe?,
    :render_sent_at,
    intent_revision: 0,
    window_observations: %{}
  ]

  @type t :: %__MODULE__{
          layout: MingaEditor.Layout.t() | nil,
          focus_tree: MingaEditor.FocusTree.t() | nil,
          shell_id: atom(),
          shell_identity: MingaEditor.Shell.Identity.t() | nil,
          modeline_click_regions: term(),
          tab_bar_click_regions: term(),
          frame_seq: non_neg_integer(),
          keyframe?: boolean(),
          render_sent_at: integer(),
          intent_revision: non_neg_integer(),
          window_observations: %{optional(MingaEditor.Window.id()) => WindowObservation.t()}
        }

  @doc "Builds a focused receipt from a completed pipeline frame."
  @spec from_output(Input.t(), non_neg_integer(), integer(), non_neg_integer()) :: t()
  def from_output(%Input{} = output, frame_seq, sent_at, intent_revision)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(sent_at) do
    %__MODULE__{
      layout: output.layout,
      focus_tree: output.focus_tree,
      shell_id: output.shell_id,
      shell_identity: output.shell_identity,
      modeline_click_regions: shell_field(output.shell_state, :modeline_click_regions),
      tab_bar_click_regions: shell_field(output.shell_state, :tab_bar_click_regions),
      frame_seq: frame_seq,
      keyframe?: output.caches.last_frame_keyframe?,
      render_sent_at: sent_at,
      intent_revision: intent_revision,
      window_observations: window_observations(output)
    }
  end

  @doc "Returns the receipt correlated to the normalized Editor intent revision."
  @spec correlate(t(), non_neg_integer()) :: t()
  def correlate(%__MODULE__{} = receipt, revision)
      when is_integer(revision) and revision >= 0,
      do: %{receipt | intent_revision: revision}

  @spec window_observations(Input.t()) :: %{
          optional(MingaEditor.Window.id()) => WindowObservation.t()
        }
  defp window_observations(%Input{workspace: %{windows: %Windows{map: windows}}}) do
    Enum.reduce(windows, %{}, fn {id, window}, observations ->
      case WindowObservation.from_window(window) do
        %WindowObservation{} = observation -> Map.put(observations, id, observation)
        nil -> observations
      end
    end)
  end

  @spec shell_field(term(), atom()) :: term()
  defp shell_field(shell_state, field) when is_map(shell_state), do: Map.get(shell_state, field)
  defp shell_field(_shell_state, _field), do: nil
end
