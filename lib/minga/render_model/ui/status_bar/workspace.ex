defmodule Minga.RenderModel.UI.StatusBar.Workspace do
  @moduledoc false

  @type kind :: :manual | :agent
  @type status :: :idle | :thinking | :tool_executing | :error | :plan | nil

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          icon: String.t(),
          status: status(),
          attention_count: non_neg_integer(),
          draft_count: non_neg_integer(),
          conflict_count: non_neg_integer(),
          running_background_count: non_neg_integer(),
          closeable?: boolean(),
          attention?: boolean()
        }

  @enforce_keys [:id, :kind, :label, :icon]
  defstruct id: 0,
            kind: :manual,
            label: "",
            icon: "",
            status: :idle,
            attention_count: 0,
            draft_count: 0,
            conflict_count: 0,
            running_background_count: 0,
            closeable?: false,
            attention?: false
end
