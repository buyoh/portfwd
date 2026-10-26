require 'minitest/autorun'
require 'tmpdir'

require_relative '../tools/lib/config_dsl'

describe 'ConfigDSL' do
  before do
    @tmpdir = Dir.mktmpdir
  end

  after do
    FileUtils.remove_entry(@tmpdir)
  end

  def write_config(content)
    path = File.join(@tmpdir, 'config.rb')
    File.write(path, content)
    path
  end

  it 'should collect nodes declared by `p_conn` with their dependencies' do
    path = write_config(<<~RUBY)
      v1 = p_conn(host: 'host1', check_tcps: [{ host: 'localhost', port: 8080 }])
      v2 = p_conn(host: 'host2', check_tcps: [])
      v1.then(v2)
    RUBY

    nodes = ConfigDSL.load_file(path)
    assert_equal(%w[host1 host2], nodes.map(&:host))
    assert_equal([{ host: 'localhost', port: 8080 }], nodes[0].info[:check_tcps])
    assert_equal([nodes[1]], nodes[0].after_nodes)
    assert_equal([nodes[0]], nodes[1].before_nodes)
  end

  it 'should load the sample config' do
    nodes = ConfigDSL.load_file(File.expand_path('../ssh/config.rb', __dir__))
    assert_equal(%w[portfwd portfwd2], nodes.map(&:host))
  end

  it 'should not let config.rb overwrite the node list' do
    path = write_config(<<~RUBY)
      p_conn(host: 'host1')
      @nodes = []
      @logger = nil
    RUBY

    assert_equal(%w[host1], ConfigDSL.load_file(path).map(&:host))
  end

  it 'should not expose local variables of the loader to config.rb' do
    path = write_config(<<~RUBY)
      p_conn(host: 'host1')
      nodes = []
      raise 'leaked' if binding.local_variable_defined?(:source) || binding.local_variable_defined?(:context)
    RUBY

    assert_equal(%w[host1], ConfigDSL.load_file(path).map(&:host))
  end

  it 'should raise ConfigDSL::Error when `p_conn` is given a non-Hash' do
    error = assert_raises(ConfigDSL::Error) { ConfigDSL.load_file(write_config("p_conn('host1')\n")) }
    assert_includes(error.message, 'p_conn expects a Hash')
  end

  it 'should not define `p_conn` globally' do
    ConfigDSL.load_file(write_config("p_conn(host: 'host1')\n"))
    assert(!Object.private_method_defined?(:p_conn))
    assert(!Object.method_defined?(:p_conn))
  end

  it 'should evaluate each file independently' do
    ConfigDSL.load_file(write_config("p_conn(host: 'host1')\n"))
    assert_equal(%w[host2], ConfigDSL.load_file(write_config("p_conn(host: 'host2')\n")).map(&:host))
  end

  it 'should raise ConfigDSL::Error for a missing file' do
    error = assert_raises(ConfigDSL::Error) { ConfigDSL.load_file(File.join(@tmpdir, 'nonexistent.rb')) }
    assert_includes(error.message, 'nonexistent.rb')
  end

  it 'should raise ConfigDSL::Error for a syntax error' do
    assert_raises(ConfigDSL::Error) { ConfigDSL.load_file(write_config("p_conn(host: 'host1'\n")) }
  end

  it 'should raise ConfigDSL::Error when config.rb calls exit' do
    error = assert_raises(ConfigDSL::Error) { ConfigDSL.load_file(write_config("p_conn(host: 'host1')\nexit 0\n")) }
    assert_includes(error.message, 'exit')
  end

  it 'should raise ConfigDSL::Error for an error while evaluating' do
    error = assert_raises(ConfigDSL::Error) { ConfigDSL.load_file(write_config("undefined_dsl_method\n")) }
    assert_includes(error.message, 'NameError')
  end
end
