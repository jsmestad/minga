defmodule Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack.FirstLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_cleanup_ok,
      label: "Language Pack Cleanup Ok",
      comment_token: "# ",
      extensions: ["language_pack_cleanup_ok"]
    }
  end
end
