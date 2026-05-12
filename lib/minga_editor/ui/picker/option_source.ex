defmodule MingaEditor.UI.Picker.OptionSource do
  @moduledoc """
  Picker source for describing editor options.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Config.Options
  alias MingaEditor.Commands.Help
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Options"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = context) do
    options_server = options_server(context)
    filetype = current_filetype(context)
    buffer = active_buffer(context)

    (builtin_items(options_server, filetype, buffer) ++ extension_items(options_server, filetype))
    |> Enum.sort_by(& &1.label)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:extension, extension, name}}, state)
      when is_atom(extension) and is_atom(name) do
    Help.describe_extension_option(state, extension, name)
  end

  def on_select(%Item{id: name}, state) when is_atom(name) do
    Help.describe_option(state, name)
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec builtin_items(Options.server(), atom() | nil, pid() | nil) :: [Item.t()]
  defp builtin_items(options_server, filetype, buffer) do
    Enum.map(Options.option_specs(), fn {name, _type, default, description} ->
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

  @spec extension_items(Options.server(), atom() | nil) :: [Item.t()]
  defp extension_items(options_server, filetype) do
    Enum.map(Options.extension_option_specs(options_server), fn %{
                                                                  extension: extension,
                                                                  name: name,
                                                                  default: default,
                                                                  description: description
                                                                } ->
      current =
        Options.get_extension_option_for_filetype(options_server, extension, name, filetype)

      changed? = current != default

      %Item{
        id: {:extension, extension, name},
        label: option_label("#{extension}.#{name}", changed?),
        description: "#{inspect(current)}  #{description}",
        annotation: option_annotation(changed?)
      }
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

  @spec option_label(atom() | String.t(), boolean()) :: String.t()
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
