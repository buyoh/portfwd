require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__) unless defined?(REPO_ROOT)

describe 'portfwd.service.erb' do
  before do
    @tmpdir = Dir.mktmpdir
    @unit_path = File.join(@tmpdir, 'portfwd.service')
  end

  after do
    FileUtils.remove_entry(@tmpdir)
  end

  def render(**vars)
    args = vars.map { |name, value| "#{name}=#{value}" }
    _out, status = Open3.capture2e('ruby', File.join(REPO_ROOT, 'tools', 'render_erb.rb'),
                                   File.join(REPO_ROOT, 'portfwd.service.erb'), @unit_path, *args)
    status
  end

  def default_vars
    { app_dir: '/opt/mai-portfwd', ssh_dir: '/opt/mai-portfwd/.ssh', ruby: '/usr/bin/ruby',
      user: 'mai-portfwd', group: 'nogroup' }
  end

  def unit_lines
    File.readlines(@unit_path, chomp: true)
  end

  it 'should start after the network is online' do
    assert(render(**default_vars).success?)
    assert_includes(unit_lines, 'Wants=network-online.target')
    assert_includes(unit_lines, 'After=network-online.target')
  end

  it 'should run the given ruby as the given user' do
    assert(render(**default_vars, ruby: '/usr/local/bin/ruby').success?)
    assert_includes(unit_lines, 'User=mai-portfwd')
    assert_includes(unit_lines, 'Group=nogroup')
    assert_includes(unit_lines, 'ExecStart=/usr/local/bin/ruby /opt/mai-portfwd/lib/main.rb /opt/mai-portfwd/.ssh')
  end

  it 'should be hardened' do
    assert(render(**default_vars).success?)
    %w[NoNewPrivileges=yes CapabilityBoundingSet= ProtectSystem=strict ProtectHome=yes PrivateTmp=yes].each do |line|
      assert_includes(unit_lines, line)
    end
  end

  it 'should keep home directories readable when the code or ruby lives there' do
    assert(render(**default_vars, app_dir: '/home/someone/portfwd').success?)
    assert_includes(unit_lines, 'ProtectHome=read-only')

    assert(render(**default_vars, ruby: '/root/.rbenv/shims/ruby').success?)
    assert_includes(unit_lines, 'ProtectHome=read-only')
  end

  it 'should let root read the files of the invoking user under a home directory' do
    assert(render(**default_vars, user: 'root', group: 'root').success?)
    assert_includes(unit_lines, 'User=root')
    assert_includes(unit_lines, 'CapabilityBoundingSet=')

    assert(render(**default_vars, app_dir: '/home/someone/portfwd', user: 'root', group: 'root').success?)
    assert_includes(unit_lines, 'CapabilityBoundingSet=CAP_DAC_READ_SEARCH')
  end

  it 'should resolve symlinks to decide whether ruby is under a home directory' do
    skip 'needs a temporary directory outside home directories' if File.realpath(@tmpdir).start_with?('/home/')
    skip 'needs a home directory under /home or /root' unless File.realpath(Dir.home).start_with?('/home/', '/root')
    # any existing path under the home directory works as the link target
    link = File.join(@tmpdir, 'ruby')
    File.symlink(Dir.home, link)

    assert(render(**default_vars, ruby: link).success?)
    assert_includes(unit_lines, 'ProtectHome=read-only')
  end

  it 'should pass systemd-analyze verify' do
    skip 'systemd-analyze is not available' unless system('command -v systemd-analyze > /dev/null 2>&1')
    assert(render(**default_vars, ruby: RbConfig.ruby).success?)
    out, status = Open3.capture2e('systemd-analyze', 'verify', @unit_path)
    assert(status.success?, out)
    assert(!out.include?(File.basename(@unit_path)), out)
  end

  it 'should fail without user or group' do
    assert(!render(**default_vars.except(:user)).success?)
    assert(!render(**default_vars, group: '').success?)
    assert(!File.exist?(@unit_path))
  end
end

describe 'tools/render_erb.rb' do
  def run_render(*args)
    _out, status = Open3.capture2e('ruby', File.join(REPO_ROOT, 'tools', 'render_erb.rb'), *args)
    status
  end

  it 'should reject malformed or duplicate variables' do
    Dir.mktmpdir do |dir|
      template = File.join(dir, 'template.erb')
      output = File.join(dir, 'output')
      File.write(template, "<%= name %>\n")

      assert(run_render(template, output, 'name=a').success?)
      assert_equal("a\n", File.read(output))
      assert(!run_render(template, output, 'name').success?)
      assert(!run_render(template, output, 'bad-name=a').success?)
      assert(!run_render(template, output, 'name=a', 'name=b').success?)
    end
  end
end
