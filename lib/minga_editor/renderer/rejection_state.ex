defmodule MingaEditor.Renderer.RejectionState do
  @moduledoc "Terminal frontend failure and one-shot adapted-retry evidence."

  alias MingaEditor.Frontend.ResourcePolicy
  alias MingaEditor.RenderPipeline.Intent

  @type terminal :: %{
          required(:generation) => non_neg_integer(),
          required(:frame_seq) => non_neg_integer(),
          required(:last_good_frame_seq) => non_neg_integer(),
          required(:reason) => atom(),
          required(:intent) => Intent.t()
        }

  @type adaptation :: %{
          required(:generation) => non_neg_integer(),
          required(:frame_seq) => non_neg_integer(),
          required(:dimension) => ResourcePolicy.dimension(),
          required(:rejected_value) => pos_integer(),
          required(:adapted_value) => pos_integer(),
          required(:intent) => Intent.t()
        }

  defstruct terminal: nil, adaptation: nil

  @type t :: %__MODULE__{
          terminal: terminal() | nil,
          adaptation: adaptation() | nil
        }

  @doc "Returns empty rejection state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records a terminal failure while retaining the rejected semantic intent."
  @spec terminal(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), atom(), Intent.t()) ::
          t()
  def terminal(%__MODULE__{} = state, generation, frame_seq, last_good, reason, intent) do
    %{
      state
      | terminal: %{
          generation: generation,
          frame_seq: frame_seq,
          last_good_frame_seq: last_good,
          reason: reason,
          intent: intent
        },
        adaptation: nil
    }
  end

  @doc "Records producer-local evidence bound to one rejected transaction and adapted intent."
  @spec adapt(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          ResourcePolicy.adaptation_descriptor(),
          Intent.t()
        ) :: t()
  def adapt(%__MODULE__{} = state, generation, frame_seq, descriptor, intent) do
    evidence =
      descriptor
      |> Map.merge(%{generation: generation, frame_seq: frame_seq, intent: intent})

    %{state | adaptation: evidence}
  end

  @doc "Clears terminal visibility and adaptation evidence after a material state change."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: new()

  @doc "Returns whether an intent is byte-for-byte the same semantic intent that failed terminally."
  @spec blocks?(t(), Intent.t()) :: boolean()
  def blocks?(%__MODULE__{terminal: %{intent: intent}}, intent), do: true
  def blocks?(%__MODULE__{}, %Intent{}), do: false
end
