defmodule MingaEditor.Renderer.RenderReceipt do
  @moduledoc """
  Focused Renderer-to-Editor process receipt.

  Receipts contain only editor-owned transition results and frame correlation
  metadata. Resident stores, window render caches, adapter caches, font state,
  acknowledgement leases, and message-store cursors never cross back.
  """

  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.ReviewObservation
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Windows

  @type observation :: WindowObservation.t() | ReviewObservation.t()
  @enforce_keys [
    :layout,
    :focus_tree,
    :shell_id,
    :shell_identity,
    :click_regions,
    :frame_seq,
    :keyframe?,
    :render_sent_at
  ]
  defstruct [
    :layout,
    :focus_tree,
    :shell_id,
    :shell_identity,
    :click_regions,
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
          click_regions: ClickRegions.t() | nil,
          frame_seq: non_neg_integer(),
          keyframe?: boolean(),
          render_sent_at: integer(),
          intent_revision: non_neg_integer(),
          window_observations: %{optional(MingaEditor.Window.id()) => observation()}
        }

  @doc "Builds a focused receipt from a completed pipeline frame."
  @spec from_output(Input.t(), non_neg_integer(), integer(), non_neg_integer()) :: t()
  def from_output(%Input{} = output, frame_seq, sent_at, intent_revision)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(sent_at) do
    frame = output.intent.frame

    %__MODULE__{
      layout: output.layout,
      focus_tree: output.focus_tree,
      shell_id: frame.shell_id,
      shell_identity: frame.shell_identity,
      click_regions: click_regions(frame.shell_state, output.caches.chrome_prev_result),
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
          optional(MingaEditor.Window.id()) => observation()
        }
  defp window_observations(%Input{windows: %Windows{map: windows}}) do
    Enum.reduce(windows, %{}, fn {id, window}, observations ->
      case window_observation(window) do
        nil -> observations
        observation -> Map.put(observations, id, observation)
      end
    end)
  end

  @spec window_observation(RenderWindow.t()) :: observation() | nil
  defp window_observation(%RenderWindow{content: {:agent_review, :semantic}} = window),
    do: ReviewObservation.from_window(window)

  defp window_observation(%RenderWindow{} = window), do: WindowObservation.from_window(window)

  @spec click_regions(term(), term()) :: ClickRegions.t() | nil
  defp click_regions(%TraditionalState{}, %Chrome{} = chrome) do
    ClickRegions.install(
      %ClickRegions{},
      chrome.modeline_click_regions,
      chrome.tab_bar_click_regions
    )
  end

  defp click_regions(_shell_state, _chrome), do: nil
end
