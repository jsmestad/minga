#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"

MANIFEST = File.expand_path("tree-sitter-vendors.txt", __dir__)

def semver?(ref)
  ref.match?(/\Av?\d+(?:\.\d+){1,3}\z/)
end

def semver_key(ref)
  parts = ref.sub(/\Av/, "").split(".").map(&:to_i)
  parts + [0] * (3 - parts.size)
end

def latest_tag(repo)
  output, error, status = Open3.capture3("git", "ls-remote", "--tags", "https://github.com/#{repo}.git")
  raise "git ls-remote failed for #{repo}: #{error.lines.first}" unless status.success?

  output
    .lines
    .filter_map { |line| line.split(/\s+/, 2)[1] }
    .map { |ref| ref.sub(%r{\Arefs/tags/}, "").sub(/\^\{\}\z/, "") }
    .select { |tag| semver?(tag) }
    .uniq
    .max_by { |tag| semver_key(tag) }
end

changed = false

updated_lines = File.readlines(MANIFEST, chomp: true).map do |line|
  next line if line.strip.empty? || line.start_with?("#")

  fields = line.split("|", -1)
  next line if fields.length < 4
  kind, name, repo, ref = fields
  next line unless %w[core grammar].include?(kind)
  next line unless semver?(ref)

  latest = latest_tag(repo)
  next line if latest.nil? || semver_key(latest) <= semver_key(ref)

  warn "#{name}: #{ref} -> #{latest}"
  fields[3] = latest
  changed = true
  fields.join("|")
end

if changed
  File.write(MANIFEST, updated_lines.join("\n") + "\n")
else
  warn "tree-sitter vendor manifest is current"
end
