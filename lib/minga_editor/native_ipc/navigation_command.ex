defmodule MingaEditor.NativeIPC.NavigationCommand do
  @moduledoc "Typed, finite semantic navigation request accepted by the local native IPC boundary."

  alias MingaEditor.NativeIPC.OperationReceipt.Target

  @maximum_u64 18_446_744_073_709_551_615
  @transport_fields ["version", "deadline_ms"]
  @identity_fields ["type", "app_instance_id", "core_instance_id", "target_token"]

  @type kind :: :focus_pane | :select_tab | :goto_location | :activate_picker_choice
  @type choice_kind :: :item | :action

  @enforce_keys [:kind, :app_instance_id, :core_instance_id, :target_token]
  defstruct [
    :kind,
    :app_instance_id,
    :core_instance_id,
    :target_token,
    :tab_id,
    :pane_id,
    :buffer_id,
    :buffer_revision,
    :line,
    :column,
    :picker_generation,
    :activation_id,
    :choice_kind
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          app_instance_id: String.t(),
          core_instance_id: String.t(),
          target_token: non_neg_integer(),
          tab_id: pos_integer() | nil,
          pane_id: pos_integer() | nil,
          buffer_id: non_neg_integer() | nil,
          buffer_revision: non_neg_integer() | nil,
          line: pos_integer() | nil,
          column: non_neg_integer() | nil,
          picker_generation: pos_integer() | nil,
          activation_id: pos_integer() | nil,
          choice_kind: choice_kind() | nil
        }

  @doc "Parses one supported wire command without creating atoms or accepting executable input."
  @spec parse(map()) :: {:ok, t()} | {:error, atom()}
  def parse(
        %{
          "type" => "focus_pane",
          "app_instance_id" => app,
          "core_instance_id" => core,
          "tab_id" => tab_id,
          "pane_id" => pane_id,
          "target_token" => token
        } = command
      ) do
    with :ok <- validate_keys(command, ["tab_id", "pane_id"]) do
      build(:focus_pane, app, core, token, tab_id: tab_id, pane_id: pane_id)
    end
  end

  def parse(
        %{
          "type" => "select_tab",
          "app_instance_id" => app,
          "core_instance_id" => core,
          "tab_id" => tab_id,
          "target_token" => token
        } = command
      ) do
    with :ok <- validate_keys(command, ["tab_id"]) do
      build(:select_tab, app, core, token, tab_id: tab_id)
    end
  end

  def parse(
        %{
          "type" => "goto_location",
          "app_instance_id" => app,
          "core_instance_id" => core,
          "tab_id" => tab_id,
          "pane_id" => pane_id,
          "target_token" => token,
          "buffer_id" => buffer_id,
          "buffer_revision" => revision,
          "line" => line,
          "column" => column
        } = command
      ) do
    with :ok <-
           validate_keys(command, [
             "tab_id",
             "pane_id",
             "buffer_id",
             "buffer_revision",
             "line",
             "column"
           ]) do
      build(:goto_location, app, core, token,
        tab_id: tab_id,
        pane_id: pane_id,
        buffer_id: buffer_id,
        buffer_revision: revision,
        line: line,
        column: column
      )
    end
  end

  def parse(
        %{
          "type" => "activate_picker_choice",
          "app_instance_id" => app,
          "core_instance_id" => core,
          "target_token" => token,
          "picker_generation" => generation,
          "activation_id" => activation_id,
          "choice_kind" => choice_kind
        } = command
      ) do
    with :ok <-
           validate_keys(command, ["picker_generation", "activation_id", "choice_kind"]),
         {:ok, parsed_kind} <- parse_choice_kind(choice_kind) do
      build(:activate_picker_choice, app, core, token,
        picker_generation: generation,
        activation_id: activation_id,
        choice_kind: parsed_kind
      )
    end
  end

  def parse(_command), do: {:error, :invalid_navigation_request}

  @spec validate_keys(map(), [String.t()]) :: :ok | {:error, :invalid_navigation_request}
  defp validate_keys(command, operation_fields) do
    allowed = @transport_fields ++ @identity_fields ++ operation_fields

    if Enum.all?(Map.keys(command), &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_navigation_request}
  end

  @doc "Returns the receipt target admitted before serialized Editor application."
  @spec receipt_target(t()) :: Target.t()
  def receipt_target(%__MODULE__{} = command) do
    %Target{
      token: command.target_token,
      kind: command.kind,
      path: nil,
      window_id: command.pane_id || 0,
      tab_id: command.tab_id,
      buffer_id: command.buffer_id,
      picker_generation: command.picker_generation,
      activation_id: command.activation_id
    }
  end

  @spec build(kind(), term(), term(), term(), keyword()) :: {:ok, t()} | {:error, atom()}
  defp build(kind, app, core, token, fields)
       when is_binary(app) and byte_size(app) > 0 and is_binary(core) and byte_size(core) > 0 do
    with {:ok, parsed_token} <- parse_u64(token),
         {:ok, parsed_fields} <- parse_fields(fields) do
      {:ok,
       struct!(
         __MODULE__,
         [
           kind: kind,
           app_instance_id: app,
           core_instance_id: core,
           target_token: parsed_token
         ] ++ parsed_fields
       )}
    end
  end

  defp build(_kind, _app, _core, _token, _fields), do: {:error, :invalid_navigation_request}

  @spec parse_fields(keyword()) :: {:ok, keyword()} | {:error, atom()}
  defp parse_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn
      {:choice_kind, value}, {:ok, parsed} ->
        {:cont, {:ok, [{:choice_kind, value} | parsed]}}

      {name, value}, {:ok, parsed} ->
        case parse_field(name, value) do
          {:ok, integer} -> {:cont, {:ok, [{name, integer} | parsed]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  @spec parse_field(atom(), term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  defp parse_field(name, value)
       when name in [:tab_id, :pane_id, :line, :picker_generation, :activation_id],
       do: parse_positive(value)

  defp parse_field(name, value) when name in [:buffer_id, :buffer_revision, :column],
    do: parse_u64(value)

  defp parse_field(_name, _value), do: {:error, :invalid_navigation_request}

  @spec parse_choice_kind(term()) :: {:ok, choice_kind()} | {:error, atom()}
  defp parse_choice_kind("item"), do: {:ok, :item}
  defp parse_choice_kind("action"), do: {:ok, :action}
  defp parse_choice_kind(_value), do: {:error, :invalid_choice_kind}

  @spec parse_u64(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_navigation_request}
  defp parse_u64(value) when is_integer(value) and value >= 0 and value <= @maximum_u64,
    do: {:ok, value}

  defp parse_u64(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 and parsed <= @maximum_u64 -> {:ok, parsed}
      _other -> {:error, :invalid_navigation_request}
    end
  end

  defp parse_u64(_value), do: {:error, :invalid_navigation_request}

  @spec parse_positive(term()) :: {:ok, pos_integer()} | {:error, :invalid_navigation_request}
  defp parse_positive(value) do
    case parse_u64(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_navigation_request}
    end
  end
end
