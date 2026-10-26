require 'minitest/autorun'

LAYOUT_LIB_DIR = File.expand_path('../lib', __dir__)

# lib/ is installed and run by the service. It must not depend on tools/ (not installed),
# nor evaluate code, so that config.rb is evaluated only at setup time
describe 'layout of lib and tools' do
  def lib_sources
    Dir.glob(File.join(LAYOUT_LIB_DIR, '*.rb')).to_h { |path| [File.basename(path), File.read(path)] }
  end

  it 'should not require tools from lib' do
    lib_sources.each do |name, source|
      refute_match(/^\s*require(_relative)?\b.*tools/, source, name)
    end
  end

  it 'should not evaluate code in lib' do
    lib_sources.each do |name, source|
      refute_match(/\b(eval|instance_eval|class_eval|module_eval|instance_exec|load|unsafe_load|unsafe_load_file)\b/,
                   source, name)
      refute_match(/\bMarshal\b/, source, name)
    end
  end

  it 'should not have config_dsl.rb in lib' do
    assert(!File.exist?(File.join(LAYOUT_LIB_DIR, 'config_dsl.rb')))
  end
end
