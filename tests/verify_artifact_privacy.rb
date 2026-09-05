#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"

# Exercise the distributed-artifact boundary from an ordinary checkout name.
# That name is not private content; concrete build paths still are.
Dir.mktmpdir("linnet-privacy-") do |root|
  checkout = File.join(root, "source")
  scripts = File.join(checkout, "scripts")
  FileUtils.mkdir_p(scripts)
  scanner = File.join(scripts, "build-privacy")
  FileUtils.cp(File.expand_path("../scripts/build-privacy", __dir__), scanner)
  artifact = File.join(root, "artifact", "Resources")
  FileUtils.mkdir_p(artifact)
  content = File.join(artifact, "source.txt")

  {
    "source resource Resources; https://github.com/Ares-X/Linnet" => true,
    "#{checkout}/sources/Main.swift" => false,
    "/Users/another-builder/project/Main.swift" => false,
    "/private/var/folders/aa/bb/Build" => false,
    "Linnet/DerivedData/Build" => false,
  }.each do |bytes, accepted|
    File.binwrite(content, bytes)
    _, _, status = Open3.capture3("bash", scanner, "scan", File.dirname(artifact))
    abort "artifact privacy classification failed (expected #{accepted})" unless
      status.success? == accepted
  end
end
puts "Artifact privacy: PASS (ordinary source/Resources names; concrete private paths rejected)"
