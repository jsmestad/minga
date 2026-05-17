defmodule MingaEditor.UI.Picker.IndentOptionSource do
  @moduledoc """
  Picker source for indentation settings.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Config.Options
  alias MingaEditor.Commands.Help
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @indent_options [:indent_with, :tab_width]

  @impl true
  @spec title() :: String.t()
  def title, do: "Indent Settings"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = context) do
    options_server = options_server(context)
    filetype = current_filetype(context)
    buffer = active_buffer(context)

    Enum.map(@indent_options, fn name ->
      {_name, _type, default, description} = option_spec(name)
      current = current_value(options_server, name, filetype, buffer)
      changed? = current != default

      %Item{
        id: name,
        label: option_label(name, changed?),
        description: "#{inspect(current)}  #{description}",
        annotation: option_annotation(changed?)
      }
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) when name in @indent_options do
    Help.describe_option(state, name)
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec option_spec(Options.option_name()) :: {Options.option_name(), term(), term(), String.t()}
  defp option_spec(name) do
    Enum.find(Options.option_specs(), fn {option_name, _type, _default, _description} ->
      option_name == name
    end)
  end

  @spec current_value(Options.server(), Options.option_name(), atom() | nil, pid() | nil) ::
          term()
  defp current_value(options_server, name, filetype, buffer) when is_pid(buffer) do
    case Map.fetch(Buffer.local_options(buffer), name) do
      {:ok, value} -> value
      :error -> Options.get_for_filetype(options_server, name, filetype)
    end
  catch
    :exit, _ -> Options.get_for_filetype(options_server, name, filetype)
  end

  defp current_value(options_server, name, filetype, _buffer) do
    Options.get_for_filetype(options_server, name, filetype)
  end

  @spec option_label(atom(), boolean()) :: String.t()
  defp option_label(name, true), do: "● #{name}"
  defp option_label(name, false), do: "  #{name}"

  @spec option_annotation(boolean()) :: String.t()
  defp option_annotation(true), do: "modified"
  defp option_annotation(false), do: ""

  @spec options_server(Context.t()) :: Options.server()
  defp options_server(%Context{options_server: nil}), do: Options.default_server()
  defp options_server(%Context{options_server: server}), do: server

  @spec current_filetype(Context.t()) :: atom() | nil
  defp current_filetype(context) do
    case active_buffer(context) do
      nil -> nil
      buffer -> Buffer.filetype(buffer)
    end
  catch
    :exit, _ -> nil
  end

  @spec active_buffer(Context.t()) :: pid() | nil
  defp active_buffer(%Context{buffers: %{active: buffer}}) when is_pid(buffer), do: buffer
  defp active_buffer(_context), do: nil
end
