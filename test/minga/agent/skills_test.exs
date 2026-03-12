defmodule Minga.Agent.SkillsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Skills

  @moduletag :tmp_dir

  defp create_skill(dir, name, opts) do
    description = Keyword.get(opts, :description, "A test skill")
    activates_on = Keyword.get(opts, :activates_on, [])
    body = Keyword.get(opts, :body, "Skill instructions for #{name}.")

    activates_yaml =
      if activates_on == [] do
        ""
      else
        items = Enum.map_join(activates_on, "\n", &"  - #{&1}")
        "activates_on:\n#{items}\n"
      end

    skill_dir = Path.join(dir, name)
    File.mkdir_p!(skill_dir)

    content = """
    ---
    name: #{name}
    description: #{description}
    #{activates_yaml}---

    #{body}
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), content)
    skill_dir
  end

  describe "parse_skill_file/2" do
    test "parses frontmatter and body", %{tmp_dir: dir} do
      create_skill(dir, "plan", description: "Plan mode", activates_on: ["plan", "scope"])
      path = Path.join([dir, "plan", "SKILL.md"])

      assert {:ok, skill} = Skills.parse_skill_file(path, :global)
      assert skill.name == "plan"
      assert skill.description == "Plan mode"
      assert skill.activates_on == ["plan", "scope"]
      assert skill.instructions =~ "Skill instructions for plan"
      assert skill.source == :global
    end

    test "uses directory name when name is missing from frontmatter", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "my-skill")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      description: A skill without a name field
      ---

      Instructions here.
      """)

      assert {:ok, skill} = Skills.parse_skill_file(Path.join(skill_dir, "SKILL.md"), :project)
      assert skill.name == "my-skill"
    end

    test "handles file without frontmatter", %{tmp_dir: dir} do
      skill_dir = Path.join(dir, "simple")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), "Just instructions, no frontmatter.")

      assert {:ok, skill} = Skills.parse_skill_file(Path.join(skill_dir, "SKILL.md"), :global)
      assert skill.name == "simple"
      assert skill.instructions =~ "Just instructions"
    end
  end

  describe "discover/1" do
    test "discovers skills in a directory", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", description: "Plan mode")
      create_skill(skills_dir, "review", description: "Code review")

      project_root = dir
      # discover looks in .minga/skills under the project root
      skills = Skills.discover(project_root)

      names = Enum.map(skills, & &1.name)
      assert "plan" in names
      assert "review" in names
    end

    test "returns empty list when no skills directory", %{tmp_dir: dir} do
      assert Skills.discover(dir) == []
    end
  end

  describe "find/2" do
    test "finds a skill by name", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", description: "Plan mode")

      assert {:ok, skill} = Skills.find("plan", dir)
      assert skill.name == "plan"
    end

    test "returns :not_found for unknown skill", %{tmp_dir: dir} do
      assert :not_found = Skills.find("nonexistent", dir)
    end
  end

  describe "auto_activate/2" do
    test "matches keywords in user text", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", activates_on: ["plan", "scope", "design"])
      create_skill(skills_dir, "review", activates_on: ["review", "pr"])

      all_skills = Skills.discover(dir)

      matches = Skills.auto_activate(all_skills, "Let's plan the new feature")
      assert length(matches) == 1
      assert hd(matches).name == "plan"
    end

    test "case insensitive matching", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", activates_on: ["Plan"])

      all_skills = Skills.discover(dir)
      matches = Skills.auto_activate(all_skills, "let's plan")
      assert length(matches) == 1
    end

    test "does not match partial words", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", activates_on: ["plan"])

      all_skills = Skills.discover(dir)
      matches = Skills.auto_activate(all_skills, "airplane")
      assert matches == []
    end

    test "skips skills without activates_on", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "manual", activates_on: [])

      all_skills = Skills.discover(dir)
      matches = Skills.auto_activate(all_skills, "anything goes")
      assert matches == []
    end
  end

  describe "format_for_prompt/1" do
    test "returns nil for empty list" do
      assert Skills.format_for_prompt([]) == nil
    end

    test "formats active skills into prompt section", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")

      create_skill(skills_dir, "plan",
        description: "Plan mode",
        body: "Always scope before coding."
      )

      {:ok, skill} = Skills.find("plan", dir)
      result = Skills.format_for_prompt([skill])

      assert result =~ "## Active Skills"
      assert result =~ "### Skill: plan"
      assert result =~ "Always scope before coding."
    end
  end

  describe "summary/1" do
    test "shows available skills", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")
      create_skill(skills_dir, "plan", description: "Plan mode", activates_on: ["plan"])

      result = Skills.summary(dir)
      assert result =~ "Available skills"
      assert result =~ "/skill:plan"
      assert result =~ "Plan mode"
      assert result =~ "auto: plan"
    end

    test "shows message when no skills found", %{tmp_dir: dir} do
      result = Skills.summary(dir)
      assert result =~ "No skills found"
    end
  end

  describe "@include references" do
    test "resolves relative file references in instructions", %{tmp_dir: dir} do
      skills_dir = Path.join(dir, ".minga/skills")

      skill_dir =
        create_skill(skills_dir, "with-ref", body: "@include extra.md\n\nMain instructions.")

      File.write!(Path.join(skill_dir, "extra.md"), "Extra content from referenced file.")

      {:ok, skill} = Skills.find("with-ref", dir)
      formatted = Skills.format_for_prompt([skill])

      assert formatted =~ "Extra content from referenced file."
      assert formatted =~ "Main instructions."
    end
  end
end
