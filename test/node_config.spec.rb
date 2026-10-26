require 'minitest/autorun'
require 'tmpdir'

require_relative '../lib/node_config'
require_relative '../tools/lib/config_dsl'

describe 'NodeConfig' do
  before do
    @tmpdir = Dir.mktmpdir
  end

  after do
    FileUtils.remove_entry(@tmpdir)
  end

  NODE_CONFIG_SAMPLE_YAML = <<~YAML.freeze
    version: 1
    nodes:
    - host: portfwd
      check_tcps:
      - host: localhost
        port: 8080
      then:
      - portfwd2
    - host: portfwd2
      check_tcps:
      - host: localhost
        port: 8888
      then: []
  YAML

  def sample_data
    YAML.safe_load(NODE_CONFIG_SAMPLE_YAML)
  end

  def parse_data(data)
    NodeConfig.parse(YAML.dump(data))
  end

  def assert_invalid(data, location = nil)
    error = assert_raises(NodeConfig::Error) { parse_data(data) }
    assert_includes(error.message, location) if location
    error
  end

  def nodes_from_rb(source)
    path = File.join(@tmpdir, 'config.rb')
    File.write(path, source)
    ConfigDSL.load_file(path)
  end

  def summary(nodes)
    nodes.map { |node| [node.info, node.after_nodes.map(&:host), node.before_nodes.map(&:host)] }
  end

  describe 'parse' do
    it 'should read the sample format as config.rb does' do
      nodes = NodeConfig.parse(NODE_CONFIG_SAMPLE_YAML)
      expected = ConfigDSL.load_file(File.expand_path('../ssh/config.rb', __dir__))

      assert_equal(summary(expected), summary(nodes))
      assert_equal([{ host: 'localhost', port: 8080 }], nodes[0].info[:check_tcps])
      assert_equal([nodes[1]], nodes[0].after_nodes)
      assert_equal([nodes[0]], nodes[1].before_nodes)
    end

    it 'should treat a missing then as empty' do
      data = sample_data
      data['nodes'][1].delete('then')
      assert_empty(parse_data(data)[1].after_nodes)
    end

    it 'should read a file' do
      path = File.join(@tmpdir, 'config.yml')
      File.write(path, NODE_CONFIG_SAMPLE_YAML)
      assert_equal(%w[portfwd portfwd2], NodeConfig.parse_file(path).map(&:host))
    end

    it 'should raise NodeConfig::Error with the path for a missing file' do
      path = File.join(@tmpdir, 'nonexistent.yml')
      error = assert_raises(NodeConfig::Error) { NodeConfig.parse_file(path) }
      assert_includes(error.message, path)
    end

    it 'should raise NodeConfig::Error with the path for a syntax error' do
      path = File.join(@tmpdir, 'config.yml')
      File.write(path, "version: 1\nnodes: [\n")
      error = assert_raises(NodeConfig::Error) { NodeConfig.parse_file(path) }
      assert_includes(error.message, path)
    end

    it 'should reject Ruby objects, symbols and aliases' do
      [
        "--- !ruby/object:Object {}\n",
        "version: 1\nnodes:\n- host: :portfwd\n  check_tcps: []\n",
        "version: 1\nnodes:\n- host: portfwd\n  check_tcps: &a []\n- host: portfwd2\n  check_tcps: *a\n"
      ].each do |text|
        assert_raises(NodeConfig::Error, text) { NodeConfig.parse(text) }
      end
      # rejected by YAML.safe_load, not only by the validation
      ["--- !ruby/object:Object {}\n", "version: 1\nnodes:\n- host: :portfwd\n  check_tcps: []\n"].each do |text|
        error = assert_raises(NodeConfig::Error, text) { NodeConfig.parse(text) }
        assert_includes(error.message, 'Tried to load unspecified class')
      end
    end

    it 'should reject an empty document' do
      assert_raises(NodeConfig::Error) { NodeConfig.parse('') }
    end
  end

  describe 'validation' do
    it 'should reject unknown keys with the location' do
      data = sample_data
      data['extra'] = 1
      assert_invalid(data, 'top level')

      data = sample_data
      data['nodes'][1]['extra'] = 1
      assert_invalid(data, 'nodes[1]')

      data = sample_data
      data['nodes'][0]['check_tcps'][0]['extra'] = 1
      assert_invalid(data, 'nodes[0].check_tcps[0]')
    end

    it 'should reject wrong types with the location' do
      ['8080', 0, 65_536, nil].each do |port|
        data = sample_data
        data['nodes'][1]['check_tcps'][0]['port'] = port
        assert_invalid(data, 'nodes[1].check_tcps[0].port')
      end

      data = sample_data
      data['nodes'][0]['host'] = 1
      assert_invalid(data, 'nodes[0].host')

      data = sample_data
      data['nodes'][1].delete('check_tcps')
      assert_invalid(data, 'nodes[1]')

      data = sample_data
      data['nodes'][1]['then'] = 'portfwd'
      assert_invalid(data, 'nodes[1].then')

      assert_invalid({ 'version' => 1, 'nodes' => [] }, 'nodes')
      assert_invalid({ 'version' => 1, 'nodes' => {} }, 'nodes')
    end

    it 'should accept the boundary ports' do
      [1, 65_535].each do |port|
        data = sample_data
        data['nodes'][0]['check_tcps'][0]['port'] = port
        assert_equal(port, parse_data(data)[0].info[:check_tcps][0][:port])
      end
    end

    it 'should reject host aliases not matching HOST_ALIAS_PATTERN' do
      ['', '-oProxyCommand=x', '_a', 'a.b', 'a b', "portfwd\n-x"].each do |host|
        data = sample_data
        data['nodes'][1]['host'] = host
        data['nodes'][0]['then'] = [host]
        assert_invalid(data, 'nodes[0].then[0]')

        data = sample_data
        data['nodes'][1]['host'] = host
        data['nodes'][0]['then'] = []
        assert_invalid(data, 'nodes[1].host')
      end
    end

    it 'should accept host aliases matching HOST_ALIAS_PATTERN' do
      %w[a portfwd-2 Port_fwd].each do |host|
        data = sample_data
        data['nodes'][1]['host'] = host
        data['nodes'][0]['then'] = [host]
        assert_equal(['portfwd', host], parse_data(data).map(&:host))
      end
    end

    it 'should accept the hosts of check_tcps matching TCP_HOST_PATTERN' do
      %w[localhost 127.0.0.1 ::1].each do |host|
        data = sample_data
        data['nodes'][0]['check_tcps'][0]['host'] = host
        assert_equal(host, parse_data(data)[0].info[:check_tcps][0][:host])
      end
    end

    it 'should reject the hosts of check_tcps not matching TCP_HOST_PATTERN' do
      ['', '-x', 'a b', "localhost\n", 1].each do |host|
        data = sample_data
        data['nodes'][0]['check_tcps'][0]['host'] = host
        assert_invalid(data, 'nodes[0].check_tcps[0].host')
      end
    end

    it 'should reject an unsupported or missing version' do
      data = sample_data
      data['version'] = 2
      assert_invalid(data, 'version')

      data = sample_data
      data['version'] = 1.0
      assert_invalid(data, 'version')

      data = sample_data
      data.delete('version')
      assert_invalid(data, 'version')
    end

    it 'should reject duplicate hosts' do
      data = sample_data
      data['nodes'][1]['host'] = 'portfwd'
      data['nodes'][0]['then'] = []
      assert_invalid(data, 'duplicate host')
    end

    it 'should reject then with an unknown host' do
      data = sample_data
      data['nodes'][0]['then'] = ['portfwd3']
      assert_invalid(data, 'nodes[0].then[0]')
    end
  end

  describe 'dump' do
    it 'should keep the order of the nodes, then and check_tcps' do
      nodes = nodes_from_rb(<<~RUBY)
        c = p_conn(host: 'c', check_tcps: [{ host: 'localhost', port: 3 }, { host: '::1', port: 1 }])
        a = p_conn(host: 'a', check_tcps: [])
        b = p_conn(host: 'b', check_tcps: [{ host: '127.0.0.1', port: 2 }])
        c.then(b)
        c.then(a)
        c.then(b)
      RUBY

      parsed = NodeConfig.parse(NodeConfig.dump(nodes))
      assert_equal(summary(nodes), summary(parsed))
      assert_equal(%w[b a b], parsed[0].after_nodes.map(&:host))
    end

    it 'should keep host aliases that look like other YAML types' do
      hosts = %w[1 yes y null true on 0x1f 1e3]
      nodes = hosts.map { |host| Node.new({ host: host, check_tcps: [] }) }
      assert_equal(hosts, NodeConfig.parse(NodeConfig.dump(nodes)).map(&:host))
    end

    it 'should output a generated file without Ruby tags' do
      yaml = NodeConfig.dump(nodes_from_rb(File.read(File.expand_path('../ssh/config.rb', __dir__))))
      assert(yaml.start_with?("# Generated from config.rb by tools/generate_config.rb. Do not edit.\n"), yaml)
      refute_includes(yaml, '!ruby')
      refute_includes(yaml, '&')
    end

    it 'should reject unknown keys of p_conn' do
      error = assert_raises(NodeConfig::Error) { NodeConfig.dump(nodes_from_rb("p_conn(host: 'a', check_tcps: [], user: 'x')\n")) }
      assert_includes(error.message, ':user')

      error = assert_raises(NodeConfig::Error) do
        NodeConfig.dump(nodes_from_rb("p_conn(host: 'a', check_tcps: [{ host: 'localhost', port: 1, timeout: 1 }])\n"))
      end
      assert_includes(error.message, ':timeout')
    end

    it 'should reject nodes which cannot be converted' do
      ["p_conn(host: 'a', check_tcps: {})\n",
       "p_conn(host: 'a', check_tcps: [1])\n",
       "p_conn('host' => 'a', check_tcps: [])\n",
       "p_conn(host: :a, check_tcps: [])\n",
       "p_conn(host: 'a')\n"].each do |source|
        assert_raises(NodeConfig::Error, source) { NodeConfig.dump(nodes_from_rb(source)) }
      end
      assert_raises(NodeConfig::Error) { NodeConfig.dump([Node.new('a')]) }
    end
  end
end
