#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require_relative "../src/photon/env"
require_relative "../src/photon/package"

class IndexGenerator
  def initialize(nuclei_dir:, output_dir:, base_url: "")
    @nuclei_dir = nuclei_dir
    @output_dir = output_dir
    @base_url = base_url
  end

  def run
    FileUtils.mkdir_p(@output_dir)
    FileUtils.mkdir_p(File.join(@output_dir, "nuclei"))
    FileUtils.mkdir_p(File.join(@output_dir, "packages"))

    packages = []
    errors = []

    Dir.glob(File.join(@nuclei_dir, "*.nuclei")).sort.each do |file|
      process_nuclei_file(file, packages, errors)
    end

    Dir.glob(File.join(@nuclei_dir, "*", "*.nuclei")).sort.each do |file|
      process_nuclei_file(file, packages, errors)
    end

    packages.sort_by! { |p| p["atom"] }

    index_data = {
      "repo_name" => "photon-main",
      "generated_at" => Time.now.utc.iso8601,
      "package_count" => packages.length,
      "base_url" => @base_url,
      "packages" => packages
    }

    File.write(
      File.join(@output_dir, "index.json"),
      JSON.pretty_generate(index_data)
    )

    generate_html_index(packages)

    puts "Generated index with #{packages.length} packages"
    puts "Errors: #{errors.length}"
    errors.each { |e| puts "  [error] #{e}" }

    { packages: packages.length, errors: errors.length }
  end

  private

  def process_nuclei_file(file, packages, errors)
    begin
      pkg = Photon::Package.load_from_nuclei(file)
      entry = package_to_index_entry(pkg, file)
      packages << entry
    rescue => e
      errors << "#{file}: #{e.message}"
    end
  end

  def package_to_index_entry(pkg, file)
    category = pkg.category || infer_category(file)
    atom = "#{category}/#{pkg.name}"

    source_url = pkg.sources.first
    checksum_data = pkg.checksums&.values&.first
    checksum = checksum_data&.dig(:hash) || checksum_data&.dig("hash") || ""
    algorithm = checksum_data&.dig(:algorithm) || checksum_data&.dig("algorithm") || "sha256"

    recipe_relpath = file.sub("#{@nuclei_dir}/", "")
    recipe_content = File.read(file)
    recipe_sha256 = Digest::SHA256.hexdigest(recipe_content)

    {
      "atom" => atom,
      "package_name" => pkg.name,
      "category" => category,
      "version" => pkg.version,
      "description" => pkg.description || "",
      "homepage" => pkg.homepage || "",
      "license" => pkg.license || "Unknown",
      "build_system" => pkg.build_system.to_s,
      "source_url" => source_url || "",
      "source_checksum" => checksum,
      "source_algorithm" => algorithm,
      "recipe_relpath" => recipe_relpath,
      "recipe_sha256" => recipe_sha256,
      "upstream_provider" => "current-recipe",
      "notes" => "",
      "origin_path" => recipe_relpath,
      "selected_from" => "current"
    }
  end

  def infer_category(file)
    rel = file.sub("#{@nuclei_dir}/", "")
    parts = rel.split("/")
    parts.length >= 2 ? parts[0] : "app"
  end

  def generate_html_index(packages)
    html = <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>Photon Packages</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark light; }
          body { max-width: 1100px; margin: 2rem auto; padding: 0 1rem; font-family: ui-sans-serif, system-ui, sans-serif; line-height: 1.5; }
          h1, h2, h3 { line-height: 1.2; }
          code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .muted { opacity: .75; }
          .card { border: 1px solid rgba(127,127,127,.3); border-radius: 12px; padding: 1rem; margin: 1rem 0; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 1rem; }
          a { text-decoration: none; color: inherit; }
          a:hover { text-decoration: underline; }
          nav { display: flex; gap: 1.5rem; padding: 1rem 0; border-bottom: 1px solid #eee; margin-bottom: 1rem; }
          nav a:hover { text-decoration: none; }
          .search { width: 100%; padding: 0.75rem; border: 1px solid #ddd; border-radius: 8px; font-size: 1rem; margin-bottom: 1rem; }
        </style>
      </head>
      <body>

      <nav>
        <strong>Photon</strong>
        <a href="index.html">Packages</a>
        <a href="contribute.html">Contribute</a>
      </nav>

        <h1>photon-main</h1>
        <p class="muted">Static Photon web repo - #{packages.length} packages</p>

        <input type="text" class="search" id="search" placeholder="Search packages..." oninput="filterPackages()">

        <div class="grid" id="packages">
    HTML

    packages.each do |pkg|
      atom = pkg["atom"]
      version = pkg["version"]
      desc = pkg["description"] || ""
      recipe = pkg["recipe_relpath"]
      meta = package_json_path(atom)

      html += <<~HTML
          <div class="card" data-name="#{atom}">
            <h3>#{atom}</h3>
            <div class="muted">Version #{version}</div>
            <p>#{desc}</p>
            <div><a href="#{recipe}">recipe</a> &middot; <a href="#{meta}">metadata</a></div>
          </div>
      HTML
    end

    html += <<~HTML
        </div>

        <script>
          function filterPackages() {
            const query = document.getElementById('search').value.toLowerCase();
            const cards = document.querySelectorAll('.card');
            cards.forEach(card => {
              const name = card.dataset.name.toLowerCase();
              card.style.display = name.includes(query) ? 'block' : 'none';
            });
          }
        </script>

        <footer style="margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #eee; color: #666;">
          <p>Generated #{Time.now.utc.iso8601}</p>
        </footer>

      </body>
      </html>
    HTML

    File.write(File.join(@output_dir, "index.html"), html)
  end

  def package_json_path(atom)
    category, name = atom.split("/", 2)
    "packages/#{category}--#{name}.json"
  end
end

if __FILE__ == $PROGRAM_NAME
  nuclei_dir = ARGV[0] || File.join(File.dirname(__FILE__), "..", "nuclei")
  output_dir = ARGV[1] || File.join(File.dirname(__FILE__), "docs")

  generator = IndexGenerator.new(nuclei_dir: nuclei_dir, output_dir: output_dir)
  generator.run
end
