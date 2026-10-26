require 'yaml'

require_relative 'node'

# The format of config.yml, which is generated from config.rb at setup time and read at runtime.
#
# config.yml is plain data: it is read by YAML.safe_load and validated strictly, so that no code
# derived from the configuration is evaluated at runtime.
#
#   version: 1
#   nodes:
#   - host: portfwd            # Host of the ssh config
#     check_tcps:
#     - host: localhost
#       port: 8080
#     then:                    # hosts started after this node (Node#then)
#     - portfwd2
module NodeConfig
  class Error < StandardError; end

  VERSION = 1
  HEADER = "# Generated from config.rb by tools/generate_config.rb. Do not edit.\n".freeze

  # Host of the ssh config, which also identifies a node. Must not start with '-' (an option of ssh)
  HOST_ALIAS_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  # destination of TCPSocket.new: a host name or an IP address (e.g. localhost, 127.0.0.1, ::1)
  TCP_HOST_PATTERN = /\A[A-Za-z0-9.:][A-Za-z0-9.:-]*\z/

  NODE_KEYS = %w[host check_tcps then].freeze
  CHECK_TCP_KEYS = %w[host port].freeze

  # Converts the nodes declared in config.rb to the data of config.yml (not validated yet).
  # Raises NodeConfig::Error if a node cannot be converted, e.g. it has an unknown key.
  def self.to_data(nodes)
    {
      'version' => VERSION,
      'nodes' => nodes.each_with_index.map { |node, i| node_to_data(node, "nodes[#{i}]") }
    }
  end

  # Raises NodeConfig::Error with the location if data is not a valid config.yml.
  def self.validate_data!(data)
    check_keys!(data, %w[version nodes], %w[version nodes], 'top level')
    raise Error, 'version: must be 1' unless data['version'].is_a?(Integer) && data['version'] == VERSION

    nodes = data['nodes']
    raise Error, 'nodes: must be a non-empty array' unless nodes.is_a?(Array) && !nodes.empty?

    nodes.each_with_index { |node, i| validate_node!(node, "nodes[#{i}]") }

    hosts = {}
    nodes.each_with_index do |node, i|
      raise Error, "nodes[#{i}].host: duplicate host '#{node['host']}'" if hosts.key?(node['host'])

      hosts[node['host']] = true
    end
    nodes.each_with_index do |node, i|
      node.fetch('then', []).each_with_index do |host, j|
        raise Error, "nodes[#{i}].then[#{j}]: unknown host '#{host}'" unless hosts.key?(host)
      end
    end
    data
  end

  # Returns the content of config.yml for the nodes.
  # Raises NodeConfig::Error if the nodes cannot be represented.
  def self.dump(nodes)
    data = to_data(nodes)
    validate_data!(data)
    HEADER + YAML.dump(data)
  end

  # Returns the nodes in the content of config.yml.
  # Raises NodeConfig::Error if the content is not a valid config.yml.
  def self.parse(text, path = '(config.yml)')
    data = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false, filename: path)
    validate_data!(data)
    data_to_nodes(data)
  rescue Psych::Exception, Error => e
    raise Error, "Invalid config #{path}: #{e.message}"
  end

  # Returns the nodes in the config.yml at path.
  # Raises NodeConfig::Error if the file cannot be read or is not a valid config.yml.
  def self.parse_file(path)
    parse(File.read(path), path)
  rescue SystemCallError => e
    raise Error, "Failed to read #{path}: #{e.message}"
  end

  class << self
    private

    def node_to_data(node, location)
      info = node.info
      raise Error, "#{location}: must be a Hash: #{info.inspect}" unless info.is_a?(Hash)

      check_symbol_keys!(info, %i[host check_tcps], location)
      data = {}
      data['host'] = info[:host] if info.key?(:host)
      if info.key?(:check_tcps)
        check_tcps = info[:check_tcps]
        raise Error, "#{location}.check_tcps: must be an Array: #{check_tcps.inspect}" unless check_tcps.is_a?(Array)

        data['check_tcps'] = check_tcps.each_with_index.map do |tcp, j|
          tcp_location = "#{location}.check_tcps[#{j}]"
          raise Error, "#{tcp_location}: must be a Hash: #{tcp.inspect}" unless tcp.is_a?(Hash)

          check_symbol_keys!(tcp, %i[host port], tcp_location)
          tcp.to_h { |key, value| [key.to_s, value] }
        end
      end
      data['then'] = node.after_nodes.map(&:host)
      data
    end

    def check_symbol_keys!(hash, allowed, location)
      unknown = hash.keys - allowed
      return if unknown.empty?

      raise Error, "#{location}: unknown keys #{unknown.map(&:inspect).join(', ')} (allowed: #{allowed.join(', ')})"
    end

    def check_keys!(value, allowed, required, location)
      raise Error, "#{location}: must be a Hash" unless value.is_a?(Hash)

      unknown = value.keys - allowed
      raise Error, "#{location}: unknown keys #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

      missing = required - value.keys
      raise Error, "#{location}: missing keys #{missing.join(', ')}" unless missing.empty?
    end

    def validate_node!(node, location)
      check_keys!(node, NODE_KEYS, %w[host check_tcps], location)
      validate_string!(node['host'], HOST_ALIAS_PATTERN, "#{location}.host")

      check_tcps = node['check_tcps']
      raise Error, "#{location}.check_tcps: must be an array" unless check_tcps.is_a?(Array)

      check_tcps.each_with_index do |tcp, j|
        tcp_location = "#{location}.check_tcps[#{j}]"
        check_keys!(tcp, CHECK_TCP_KEYS, CHECK_TCP_KEYS, tcp_location)
        validate_string!(tcp['host'], TCP_HOST_PATTERN, "#{tcp_location}.host")
        port = tcp['port']
        unless port.is_a?(Integer) && port.between?(1, 65_535)
          raise Error, "#{tcp_location}.port: must be an integer between 1 and 65535: #{port.inspect}"
        end
      end

      return unless node.key?('then')

      after_hosts = node['then']
      raise Error, "#{location}.then: must be an array" unless after_hosts.is_a?(Array)

      after_hosts.each_with_index do |host, j|
        validate_string!(host, HOST_ALIAS_PATTERN, "#{location}.then[#{j}]")
      end
    end

    def validate_string!(value, pattern, location)
      return if value.is_a?(String) && value.valid_encoding? && pattern.match?(value)

      raise Error, "#{location}: must be a string matching #{pattern.inspect}: #{value.inspect}"
    end

    def data_to_nodes(data)
      nodes = data['nodes'].map do |node|
        check_tcps = node['check_tcps'].map { |tcp| { host: tcp['host'], port: tcp['port'] } }
        Node.new({ host: node['host'], check_tcps: check_tcps })
      end
      nodes_by_host = nodes.to_h { |node| [node.host, node] }
      data['nodes'].each_with_index do |node, i|
        node.fetch('then', []).each { |host| nodes[i].then(nodes_by_host[host]) }
      end
      nodes
    end
  end
end
