#!/usr/bin/env ruby

require 'erb'
require 'fileutils'

if ARGV.length < 2 || ARGV.drop(2).any? { |arg| !arg.match?(/\A[a-z_][a-z0-9_]*=/) }
  warn 'Usage: ruby tools/render_erb.rb <template_path> <output_path> [<name>=<value> ...]'
  exit 1
end

template_path, output_path, *assignments = ARGV
names = assignments.map { |arg| arg.split('=', 2).first }
if names.uniq.length != names.length
  warn "Duplicate variables: #{names.select { |name| names.count(name) > 1 }.uniq.join(', ')}"
  exit 1
end
variables = assignments.to_h { |arg| arg.split('=', 2) }.transform_keys(&:to_sym)

template = File.read(template_path)
result = ERB.new(template, trim_mode: '-').result_with_hash(variables)

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, result)
