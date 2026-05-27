defmodule Minga.RenderModel.UI.Notifications do
  @moduledoc false

  @type level :: :info | :warning | :error | :success | :progress

  @type action :: %{
          id: String.t(),
          label: String.t()
        }

  @type notification_item :: %{
          id: String.t(),
          level: level(),
          title: String.t(),
          body: String.t(),
          source: String.t(),
          actions: [action()],
          dismissable: boolean(),
          auto_dismiss_ms: non_neg_integer() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  @type t :: %__MODULE__{
          items: [notification_item()]
        }

  @enforce_keys [:items]
  defstruct [:items]
end
