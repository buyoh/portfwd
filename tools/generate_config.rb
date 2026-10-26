#!/usr/bin/env ruby

# Evaluates config.rb and writes config.yml, which the service reads at runtime.
# Run at setup time only (install.sh, or before running from the working copy).

require 'logger'

require_relative 'lib/config_dsl'
require_relative '../lib/node'
require_relative '../lib/node_config'

if ARGV.length != 2
  warn 'Usage: ruby tools/generate_config.rb <config.rb> <config.yml>'
  exit 1
end

input_path, output_path = ARGV
if File.expand_path(input_path) == File.expand_path(output_path)
  warn "The input and the output are the same file: #{input_path}"
  exit 1
end

logger = Logger.new($stderr)

# checks duplicate hosts, the start node and cycles, as App does at runtime
validate_nodes = lambda do |nodes|
  exit 1 unless NodeManager.new(logger, nodes).validate_nodes
end

begin
  nodes = ConfigDSL.load_file(input_path)
  validate_nodes.call(nodes)
  yaml = NodeConfig.dump(nodes)
  # make sure the output is read back in the same way as at runtime
  validate_nodes.call(NodeConfig.parse(yaml, output_path))
rescue ConfigDSL::Error, NodeConfig::Error => e
  warn e.message
  exit 1
end

# write to a temporary file and rename it, so that a failure does not leave a partial output
tmp_path = "#{output_path}.tmp-#{Process.pid}"
# removed on failure only if created by this process (EXCL fails on an existing file, which is kept)
tmp_created = false
begin
  File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    tmp_created = true
    file.write(yaml)
  end
  File.rename(tmp_path, output_path)
  tmp_created = false
rescue SystemCallError => e
  warn "Failed to write #{output_path}: #{e.message}"
  exit 1
ensure
  File.unlink(tmp_path) if tmp_created
end
