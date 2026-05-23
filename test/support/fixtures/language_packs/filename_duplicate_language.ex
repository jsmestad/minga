defmodule Minga.Test.Fixtures.LanguagePacks.FilenameFailingPack.DuplicateLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_filename_duplicate,
      label: "Language Pack Filename Duplicate",
      comment_token: "# ",
      extensions: ["language_pack_filename_duplicate"],
      filenames: ["LanguagePackFilename"]
    }
  end
end
