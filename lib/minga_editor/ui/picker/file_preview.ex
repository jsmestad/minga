defmodule MingaEditor.UI.Picker.FilePreview do
  @moduledoc false

  alias MingaEditor.Extension.Picker.Source

  @max_lines 50

  @spec read(Path.t()) :: {:ok, Source.styled_lines()} | {:error, File.posix()}
  def read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, styled_lines(content)}
      {:error, _reason} = error -> error
    end
  end

  @spec styled_lines(binary()) :: Source.styled_lines()
  defp styled_lines(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>) do
      content
      |> String.splitter("\n")
      |> Enum.take(@max_lines)
      |> Enum.map(&[{&1, :default, false}])
    else
      [[{"Binary file preview unavailable", :default, true}]]
    end
  end
end
