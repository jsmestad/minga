defmodule MingaEditor.NativeIPC.OperationReceipt do
  @moduledoc """
  Correlated result for one authenticated local client operation.

  The receipt separates command admission, BEAM application, and the strongest
  native readiness boundary that the affected consumer can prove. Receipt
  lookup observes the original action and never resubmits it.
  """

  defmodule Target do
    @moduledoc "Core-scoped semantic target for one presentation postcondition."

    @enforce_keys [:token, :path, :window_id]
    defstruct [:token, :path, :window_id]

    @type t :: %__MODULE__{
            token: non_neg_integer(),
            path: String.t(),
            window_id: non_neg_integer()
          }

    @doc "Derives the opaque wire token for one canonical target path."
    @spec token_for_path(String.t()) :: non_neg_integer()
    def token_for_path(path) when is_binary(path) do
      <<token::unsigned-64, _rest::binary>> = :crypto.hash(:sha256, path)
      token
    end
  end

  defmodule Evidence do
    @moduledoc "Native evidence attached to a terminal receipt."

    @enforce_keys [
      :target_token,
      :application_revision,
      :boundary,
      :generation,
      :frame_seq,
      :window_id,
      :focus_ready
    ]
    defstruct [
      :target_token,
      :application_revision,
      :boundary,
      :generation,
      :frame_seq,
      :window_id,
      :focus_ready
    ]

    @type boundary :: :metal_drawable_completed | :none
    @type t :: %__MODULE__{
            target_token: non_neg_integer(),
            application_revision: non_neg_integer(),
            boundary: boundary(),
            generation: non_neg_integer(),
            frame_seq: non_neg_integer(),
            window_id: non_neg_integer(),
            focus_ready: boolean()
          }
  end

  @type phase :: :admitted | :applied | :terminal
  @type outcome ::
          :ready
          | :rejected
          | :presentation_failed
          | :hidden
          | :unavailable
          | :superseded
          | :app_replaced
          | :core_replaced
          | :indeterminate

  @enforce_keys [
    :app_instance_id,
    :core_instance_id,
    :operation_id,
    :kind,
    :target,
    :postcondition,
    :phase,
    :admitted_at_ms
  ]
  defstruct [
    :app_instance_id,
    :core_instance_id,
    :operation_id,
    :kind,
    :target,
    :postcondition,
    :phase,
    :outcome,
    :application_revision,
    :evidence,
    :last_visible,
    :detail,
    :admitted_at_ms,
    :applied_at_ms,
    :terminal_at_ms
  ]

  @type t :: %__MODULE__{
          app_instance_id: String.t(),
          core_instance_id: String.t(),
          operation_id: pos_integer(),
          kind: :open,
          target: Target.t(),
          postcondition: :editor_visible_focused,
          phase: phase(),
          outcome: outcome() | nil,
          application_revision: non_neg_integer() | nil,
          evidence: Evidence.t() | nil,
          last_visible: Evidence.t() | nil,
          detail: String.t() | nil,
          admitted_at_ms: integer(),
          applied_at_ms: integer() | nil,
          terminal_at_ms: integer() | nil
        }

  @spec admit(String.t(), String.t(), pos_integer(), String.t(), non_neg_integer(), integer()) ::
          t()
  def admit(app_instance_id, core_instance_id, operation_id, path, token, now_ms) do
    %__MODULE__{
      app_instance_id: app_instance_id,
      core_instance_id: core_instance_id,
      operation_id: operation_id,
      kind: :open,
      target: %Target{token: token, path: path, window_id: 0},
      postcondition: :editor_visible_focused,
      phase: :admitted,
      admitted_at_ms: now_ms
    }
  end

  @doc "Records the exact BEAM target after the open operation applies."
  @spec applied(t(), non_neg_integer(), non_neg_integer(), integer()) :: t()
  def applied(%__MODULE__{phase: :admitted} = receipt, window_id, revision, now_ms) do
    target = %{receipt.target | window_id: window_id}

    %{
      receipt
      | phase: :applied,
        target: target,
        application_revision: revision,
        applied_at_ms: now_ms
    }
  end

  def applied(%__MODULE__{} = receipt, _window_id, _revision, _now_ms), do: receipt

  @doc "Moves a nonterminal receipt to one terminal result exactly once."
  @spec finish(
          t(),
          outcome(),
          Evidence.t() | nil,
          Evidence.t() | nil,
          String.t() | nil,
          integer()
        ) :: t()
  def finish(%__MODULE__{phase: phase} = receipt, outcome, evidence, last_visible, detail, now_ms)
      when phase in [:admitted, :applied] do
    %{
      receipt
      | phase: :terminal,
        outcome: outcome,
        evidence: evidence,
        last_visible: last_visible,
        detail: detail,
        terminal_at_ms: now_ms
    }
  end

  def finish(%__MODULE__{} = receipt, _outcome, _evidence, _last_visible, _detail, _now_ms),
    do: receipt

  @doc "Returns the stable public JSON representation used by the native helper."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      "version" => 1,
      "app_instance_id" => receipt.app_instance_id,
      "core_instance_id" => receipt.core_instance_id,
      "operation_id" => Integer.to_string(receipt.operation_id),
      "kind" => Atom.to_string(receipt.kind),
      "phase" => Atom.to_string(receipt.phase),
      "outcome" => encode_atom(receipt.outcome),
      "postcondition" => Atom.to_string(receipt.postcondition),
      "target" => target_map(receipt.target),
      "application_revision" => receipt.application_revision,
      "evidence" => evidence_map(receipt.evidence),
      "last_visible" => evidence_map(receipt.last_visible),
      "detail" => receipt.detail,
      "admitted_at_ms" => receipt.admitted_at_ms,
      "applied_at_ms" => receipt.applied_at_ms,
      "terminal_at_ms" => receipt.terminal_at_ms
    }
  end

  @spec target_map(Target.t()) :: map()
  defp target_map(%Target{} = target) do
    %{
      "token" => Integer.to_string(target.token),
      "path" => target.path,
      "window_id" => target.window_id
    }
  end

  @spec evidence_map(Evidence.t() | nil) :: map() | nil
  defp evidence_map(nil), do: nil

  defp evidence_map(%Evidence{} = evidence) do
    %{
      "target_token" => Integer.to_string(evidence.target_token),
      "application_revision" => evidence.application_revision,
      "boundary" => Atom.to_string(evidence.boundary),
      "generation" => evidence.generation,
      "frame_seq" => evidence.frame_seq,
      "window_id" => evidence.window_id,
      "focus_ready" => evidence.focus_ready
    }
  end

  @spec encode_atom(atom() | nil) :: String.t() | nil
  defp encode_atom(nil), do: nil
  defp encode_atom(value), do: Atom.to_string(value)
end
