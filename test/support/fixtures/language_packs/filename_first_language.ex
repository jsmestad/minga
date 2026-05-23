defmodule Minga.Test.Fixtures.LanguagePacks.FilenameFailingPack.FirstLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_filename_ok,
      label: "Language Pack Filename Ok",
      comment_token: "# ",
      extensions: ["language_pack_filename_ok"],
      filenames: ["LanguagePackFilename"]
    }
  end
end
