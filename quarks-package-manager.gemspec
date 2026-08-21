# frozen_string_literal: true

src_dir = File.expand_path("src", __dir__)
$LOAD_PATH.unshift(src_dir) unless $LOAD_PATH.include?(src_dir)

require_relative "src/quarks/version"
require_relative "src/quarks/release_recipes"

recipe_files = Quarks::ReleaseRecipes.load(Dir["nuclei/**/*.nuclei"]).paths

Gem::Specification.new do |spec|
  spec.name = "quarks-package-manager"
  spec.version = Quarks::VERSION
  spec.authors = ["Quarks Developers"]
  spec.summary = "A secure, production-focused source package manager"
  spec.description = "Quarks resolves, builds in an unprivileged sandbox, and transactionally installs source packages."
  spec.homepage = "https://github.com/RobertFlexx/Quarks"
  spec.license = "BSD-3-Clause"
  spec.required_ruby_version = Gem::Requirement.new(">= 3.2", "< 4.1.dev")

  spec.files = Dir[
    "LICENSE", "README.md", "src/**/*.rb", "exe/*",
    "tools/quarks_doctor.rb", "tools/security_audit.rb",
    "tools/benchmark.rb", "tools/build_repository.rb"
  ] + recipe_files
  spec.bindir = "exe"
  spec.executables = ["quarks"]
  spec.require_paths = ["src"]

  spec.add_dependency "sqlite3", ">= 2.9.5", "< 3"
  spec.add_development_dependency "rake", ">= 13", "< 14"
  spec.add_development_dependency "minitest", ">= 5", "< 7"
  spec.add_development_dependency "benchmark", ">= 0.3", "< 1"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
end
