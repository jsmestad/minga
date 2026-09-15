defmodule MingaEditor.UI.Picker.FilesystemQuery do
  @moduledoc """
  One immutable interpretation of the complete text in a filesystem file finder.

  Parsing is lexical and performs no filesystem access. DirectorySource resolves the resulting
  directory off the Editor input process.
  """

  alias MingaEditor.UI.Picker.FindFileSession

  @enforce_keys [:identity, :text, :session, :resolution]
  defstruct [:identity, :text, :session, :resolution]

  @type resolution ::
          {:browse, directory :: String.t(), leaf :: String.t()} | {:error, String.t()}
  @type t :: %__MODULE__{
          identity: reference(),
          text: String.t(),
          session: FindFileSession.t(),
          resolution: resolution()
        }

  @doc "Builds the initial query that visibly names the captured launch directory."
  @spec initial(FindFileSession.t()) :: t()
  def initial(%FindFileSession{launch_directory: directory} = session) do
    for_directory(session, directory)
  end

  @doc "Parses a complete user query against the session's fixed anchors."
  @spec parse(FindFileSession.t(), String.t()) :: t()
  def parse(%FindFileSession{} = session, text) when is_binary(text) do
    %__MODULE__{
      identity: make_ref(),
      text: text,
      session: session,
      resolution: resolve(session, text)
    }
  end

  @doc "Builds a directory-navigation query with a trailing separator for visible path agreement."
  @spec for_directory(FindFileSession.t(), String.t()) :: t()
  def for_directory(%FindFileSession{} = session, directory) when is_binary(directory) do
    expanded = Path.expand(directory)
    text = directory_text(expanded, session.home_directory)

    %__MODULE__{
      identity: make_ref(),
      text: text,
      session: session,
      resolution: {:browse, expanded, ""}
    }
  end

  @doc "Returns whether text explicitly requests filesystem interpretation from project search."
  @spec explicit_path_intent?(String.t()) :: boolean()
  def explicit_path_intent?("/" <> _rest), do: true
  def explicit_path_intent?("~"), do: true
  def explicit_path_intent?("~/" <> _rest), do: true
  def explicit_path_intent?("."), do: true
  def explicit_path_intent?(".."), do: true
  def explicit_path_intent?("./" <> _rest), do: true
  def explicit_path_intent?("../" <> _rest), do: true
  def explicit_path_intent?(_text), do: false

  @doc "Returns the directory whose immediate children this query resolves."
  @spec directory(t()) :: {:ok, String.t()} | {:error, String.t()}
  def directory(%__MODULE__{resolution: {:browse, directory, _leaf}}), do: {:ok, directory}
  def directory(%__MODULE__{resolution: {:error, reason}}), do: {:error, reason}

  @doc "Returns whether two resolved queries use the same direct-child listing."
  @spec same_directory?(t(), t()) :: boolean()
  def same_directory?(
        %__MODULE__{resolution: {:browse, directory, _}},
        %__MODULE__{resolution: {:browse, directory, _}}
      ),
      do: true

  def same_directory?(%__MODULE__{}, %__MODULE__{}), do: false

  @doc "Returns the leaf text used to filter a resolved directory listing."
  @spec filter_text(t()) :: String.t()
  def filter_text(%__MODULE__{resolution: {:browse, _directory, leaf}}), do: leaf
  def filter_text(%__MODULE__{resolution: {:error, _message}}), do: ""

  @doc "Collapses the captured Home anchor in one absolute path for matching and display."
  @spec display_path(t(), String.t()) :: String.t()
  def display_path(%__MODULE__{session: session}, path) do
    collapse_home(Path.expand(path), session.home_directory)
  end

  @spec resolve(FindFileSession.t(), String.t()) :: resolution()
  defp resolve(%FindFileSession{home_directory: home}, "~"), do: {:browse, home, ""}
  defp resolve(%FindFileSession{home_directory: home}, "~/"), do: {:browse, home, ""}

  defp resolve(%FindFileSession{home_directory: home}, "~/" <> rest = text) do
    split_path(Path.expand(rest, home), text)
  end

  defp resolve(%FindFileSession{}, "~" <> _rest),
    do: {:error, "Named-user Home paths are not supported; use ~ or ~/"}

  defp resolve(%FindFileSession{}, "/" = text), do: {:browse, text, ""}

  defp resolve(%FindFileSession{}, "/" <> _rest = text) do
    split_path(Path.expand(text), text)
  end

  defp resolve(%FindFileSession{launch_directory: launch}, ""), do: {:browse, launch, ""}
  defp resolve(%FindFileSession{launch_directory: launch}, "."), do: {:browse, launch, ""}
  defp resolve(%FindFileSession{launch_directory: launch}, "./"), do: {:browse, launch, ""}

  defp resolve(%FindFileSession{launch_directory: launch}, "..") do
    {:browse, Path.dirname(launch), ""}
  end

  defp resolve(%FindFileSession{launch_directory: launch}, text) do
    split_path(Path.expand(text, launch), text)
  end

  @spec split_path(String.t(), String.t()) :: resolution()
  defp split_path(expanded, text) do
    if String.ends_with?(text, "/") do
      {:browse, expanded, ""}
    else
      {:browse, Path.dirname(expanded), Path.basename(expanded)}
    end
  end

  @spec directory_text(String.t(), String.t()) :: String.t()
  defp directory_text("/", _home), do: "/"

  defp directory_text(directory, home) do
    collapse_home(directory, home) <> "/"
  end

  @spec collapse_home(String.t(), String.t()) :: String.t()
  defp collapse_home(home, home), do: "~"

  defp collapse_home(path, home) do
    String.replace_prefix(path, home <> "/", "~/")
  end
end
