# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

Rake::TestTask.new do |task|
  task.libs << "src"
  task.pattern = "spec/**/*_test.rb"
  task.warning = true
end

task default: :test

desc "Compile every shipped Ruby entry point"
task :syntax do
  paths = Dir["src/**/*.rb", "tools/*.rb", "exe/*"] + ["quarks", "quarks-package-manager.gemspec", "Rakefile"]
  paths.sort.each do |path|
    ruby "-c", path, out: File::NULL
  end
  puts "Syntax OK: #{paths.length} files"
end

desc "Run security and repository release invariants"
task :security do
  ruby "tools/security_audit.rb"
end

desc "Enforce startup, scan, and lookup performance budgets"
task :performance do
  ruby "tools/benchmark.rb", "--assert"
end

desc "Build, inspect, install, and smoke-test the release gem in a temporary root"
task :package do
  ruby "tools/release_check.rb"
end

desc "Run every source, security, performance, and packaging release gate"
task release: %i[syntax test security performance package]
