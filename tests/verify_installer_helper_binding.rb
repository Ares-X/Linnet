#!/usr/bin/env ruby

# Validate the Installer execution boundary using original candidate bytes.
# This never installs or executes packaged helpers.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

abort 'usage: tests/verify_installer_helper_binding.rb COMPLETE_PKG' unless ARGV.length == 1
project = File.expand_path('..', __dir__)
package = File.realpath(ARGV.fetch(0))
tool = File.join(project, 'build/linnet-pack')
parent = File.join(project, 'build/installer-binding-tests.noindex')
FileUtils.mkdir_p(parent)
scratch = Dir.mktmpdir('candidate.', parent)
passed = false

def capture!(*arguments)
  output, error, status = Open3.capture3(*arguments)
  abort "#{arguments.first}: #{output}#{error}" unless status.success?
  output
end

begin
  expanded = File.join(scratch, 'expanded')
  capture!('/usr/sbin/pkgutil', '--expand-full', package, expanded)
  app = File.join(expanded, 'Linnet-Core.component.pkg/Payload/Linnet.payload')
  metadata = JSON.parse(File.binread(File.join(app, 'Contents/Resources/LinnetRelease/VERSION.json')))
  revision = metadata.fetch('source').fetch('candidate_revision')
  environment = {'LINNET_RELEASE_TOOL' => tool, 'LINNET_CANDIDATE_REVISION' => revision}
  repacked = File.join(scratch, 'fixture.pkg')
  verifier = File.join(project, 'package/verify_package')

  # Prove the fixture transformation preserves a valid product before mutation.
  capture!('/usr/sbin/pkgutil', '--flatten-full', expanded, repacked)
  capture!(environment, verifier, repacked, app, 'complete', 'publication')
  File.unlink(repacked)
  puts 'Installer helper binding: original repacked candidate PASS'

  [
    ['Core', 'linnet-pack', 'core/linnet-pack'],
    ['Profile', 'linnet-runtime-inspector', 'profile/linnet-runtime-inspector']
  ].each do |component, helper, expected|
    path = File.join(expanded, "Linnet-#{component}.component.pkg/Scripts", helper)
    original_size = File.size(path)
    File.open(path, 'ab') { |file| file.write("\0") }
    begin
      capture!('/usr/sbin/pkgutil', '--flatten-full', expanded, repacked)
      output, error, status = Open3.capture3(environment, verifier, repacked, app, 'complete', 'publication')
      abort "tampered helper was not rejected at its signed binding: #{output}#{error}" unless
        !status.success? && (output + error).include?("Installer content mismatch: #{expected}")
      puts "Installer helper binding: tampered #{expected} rejected"
    ensure
      File.truncate(path, original_size)
      File.unlink(repacked) if File.exist?(repacked)
    end
  end
  passed = true
ensure
  if passed && system('/usr/sbin/lsof', '+D', scratch, out: File::NULL, err: File::NULL) == false
    FileUtils.remove_entry_secure(scratch)
    puts 'Installer helper binding: task fixture cleaned'
  else
    warn "Retained fixture evidence: #{scratch}"
  end
end
