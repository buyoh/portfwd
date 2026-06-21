#!/usr/bin/env ruby

require 'erb'
require 'fileutils'

if ARGV.length != 4 && ARGV.length != 6
  warn 'Usage: ruby tools/render_erb.rb <template_path> <output_path> <app_dir> <ssh_dir> [<user> <group>]'
  exit 1
end

template_path, output_path, app_dir, ssh_dir, user, group = ARGV

template = File.read(template_path)
result = ERB.new(template, trim_mode: '-').result_with_hash(
  app_dir: app_dir,
  ssh_dir: ssh_dir,
  user: user,
  group: group
)

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, result)
