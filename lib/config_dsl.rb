require_relative 'node'

# Evaluates config.rb and collects the nodes declared by `p_conn`.
#
# config.rb is evaluated on a dedicated object which only exposes the DSL methods,
# so it cannot touch the application state (logger, node list, ...).
class ConfigDSL
  class Error < StandardError; end

  class Context
    # A binding created inside `def` does not capture the caller's local variables
    def __binding__
      binding
    end
  end

  # Returns the nodes declared in the file at path.
  # Raises ConfigDSL::Error if the file cannot be read or evaluated.
  def self.load_file(path)
    source = File.read(path)
    new.evaluate(source, path)
  rescue SystemCallError => e
    raise Error, "Failed to read #{path}: #{e.message}"
  end

  def evaluate(source, path = '(config)')
    nodes = []
    # The node list is captured by the closure and is not visible from config.rb
    context = Context.new
    context.define_singleton_method(:p_conn) do |info|
      raise ArgumentError, "p_conn expects a Hash: #{info.inspect}" unless info.is_a?(Hash)

      node = Node.new(info)
      nodes.push(node)
      node
    end
    eval(source, context.__binding__, path, 1) # rubocop:disable Security/Eval
    nodes
  rescue StandardError, ScriptError => e
    raise Error, "Failed to evaluate #{path}: #{e.class}: #{e.message}"
  end
end
