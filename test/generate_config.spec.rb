require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require_relative '../lib/node_config'

GENERATE_CONFIG_PATH = File.expand_path('../tools/generate_config.rb', __dir__)

describe 'tools/generate_config.rb' do
  before do
    @tmpdir = Dir.mktmpdir
    @input = File.join(@tmpdir, 'config.rb')
    @output = File.join(@tmpdir, 'config.yml')
  end

  after do
    FileUtils.remove_entry(@tmpdir)
  end

  def generate(*args)
    Open3.capture2e(RbConfig.ruby, GENERATE_CONFIG_PATH, *args)
  end

  def assert_fails_for(source)
    File.write(@input, source)
    out, status = generate(@input, @output)
    assert_equal(1, status.exitstatus, out)
    out
  end

  it 'should generate config.yml from the sample config.rb' do
    out, status = generate(File.expand_path('../ssh/config.rb', __dir__), @output)
    assert(status.success?, out)

    nodes = NodeConfig.parse_file(@output)
    assert_equal(%w[portfwd portfwd2], nodes.map(&:host))
    assert_equal(%w[portfwd2], nodes[0].after_nodes.map(&:host))
    assert_equal(0o600, File.stat(@output).mode & 0o777)
    assert_equal(['config.yml'], Dir.children(@tmpdir))
  end

  it 'should replace an existing output' do
    File.write(@output, 'old')
    File.write(@input, "p_conn(host: 'a', check_tcps: [])\n")
    out, status = generate(@input, @output)
    assert(status.success?, out)
    assert_equal(%w[a], NodeConfig.parse_file(@output).map(&:host))
  end

  it 'should not create or modify the output on failure' do
    ["p_conn(host: 'a'\n", "p_conn('a')\n"].each do |source|
      assert_fails_for(source)
      assert(!File.exist?(@output), source)
    end

    File.write(@output, 'old')
    assert_fails_for("p_conn(host: 'a'\n")
    assert_equal('old', File.read(@output))
    assert_equal(%w[config.rb config.yml], Dir.children(@tmpdir).sort)
  end

  it 'should fail when config.rb calls exit' do
    assert_fails_for("p_conn(host: 'a', check_tcps: [])\nexit 0\n")
    assert(!File.exist?(@output))
  end

  it 'should fail for a cycle' do
    out = assert_fails_for(<<~RUBY)
      v0 = p_conn(host: 'a', check_tcps: [])
      v1 = p_conn(host: 'b', check_tcps: [])
      v2 = p_conn(host: 'c', check_tcps: [])
      v1.then(v2)
      v2.then(v1)
    RUBY
    assert_includes(out, 'Cycle detected')
  end

  it 'should fail for duplicate hosts' do
    out = assert_fails_for("p_conn(host: 'a', check_tcps: [])\np_conn(host: 'a', check_tcps: [])\n")
    assert_includes(out, 'Duplicate host')
  end

  it 'should fail for an unknown key of p_conn' do
    out = assert_fails_for("p_conn(host: 'a', check_tcps: [], user: 'x')\n")
    assert_includes(out, ':user')
    assert(!File.exist?(@output))
  end

  it 'should fail for an invalid host alias' do
    assert_fails_for("p_conn(host: '-oProxyCommand=x', check_tcps: [])\n")
    assert(!File.exist?(@output))
  end

  it 'should fail for wrong arguments' do
    File.write(@input, "p_conn(host: 'a', check_tcps: [])\n")
    [[], [@input], [@input, @output, @output]].each do |args|
      out, status = generate(*args)
      assert_equal(1, status.exitstatus, out)
      assert_includes(out, 'Usage:')
    end

    out, status = generate(@input, File.join(@tmpdir, '.', 'config.rb'))
    assert_equal(1, status.exitstatus, out)
    assert_equal("p_conn(host: 'a', check_tcps: [])\n", File.read(@input))
  end

  it 'should remove the temporary file when the rename fails' do
    # a directory at the output makes the rename fail
    FileUtils.mkdir_p(@output)
    File.write(@input, "p_conn(host: 'a', check_tcps: [])\n")
    out, status = generate(@input, @output)
    assert_equal(1, status.exitstatus, out)
    assert(File.directory?(@output))
    assert_equal(%w[config.rb config.yml], Dir.children(@tmpdir).sort)
  end
end
