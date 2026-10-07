# frozen_string_literal: true

module I18n
  # Per-call resolution tracing.
  #
  # Tracing is enabled for a single translate call by passing the +trace+
  # option:
  #
  #   I18n.t(:foo, :trace => true)   # => "normal translation"
  #   I18n.last_trace                # => #<I18n::Trace ...>
  #
  # Alternatively an +I18n::Trace+ instance can be passed and inspected after
  # the call:
  #
  #   trace = I18n::Trace.new
  #   I18n.t(:foo, :trace => trace)
  #   trace.roots                    # => [#<I18n::Trace::Node ...>]
  #
  # The trace records which backends, locales and keys were actually tried,
  # symbol alias jumps, default usage, pluralization branch selection and the
  # final hit location. Nested translations (e.g. triggered by symbol aliases
  # or symbol defaults) form a parent/child tree of nodes.
  #
  # Tracing never re-runs lookups, Procs or interpolation to produce its
  # records: every node and event corresponds to work that really happened
  # while resolving the call. Interpolation parameter values are not recorded
  # by default; pass +I18n::Trace.new(:include_values => true)+ to include
  # them.
  #
  # The currently active trace is stored per fiber (or thread, where fibers
  # are not supported), so concurrent traced and untraced calls do not
  # interfere with each other.
  class Trace
    # Event data keys that may carry interpolation parameter values. These
    # are dropped from records unless the trace was created with
    # +include_values: true+.
    SENSITIVE_DATA_KEYS = %i[count values].freeze

    # A single step recorded while resolving a translation, e.g. a symbol
    # alias jump, a fallback locale being tried, a default being used or a
    # pluralization branch being selected.
    class Event
      attr_reader :type, :data

      def initialize(type, data)
        @type = type
        @data = data
      end

      def [](key)
        @data[key]
      end

      def to_h
        { :type => @type }.merge(@data)
      end

      def inspect
        pairs = @data.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
        pairs = " #{pairs}" unless pairs.empty?
        "#<#{self.class.name} #{@type}#{pairs}>"
      end
      alias_method :to_s, :inspect
    end

    # One node in a resolution trace. A node corresponds to a single
    # +translate+ invocation on a backend that actually happened, including
    # the locale and key it was tried with. Nested translations (symbol
    # aliases, symbol defaults, chained backends, fallback locales) appear as
    # child nodes.
    class Node
      attr_reader :backend, :locale, :key, :scope, :events, :children
      # The resolved entry as stored, before interpolation. Only set for hits.
      attr_accessor :entry
      # The final value returned by this call. Only recorded when the trace
      # was created with +include_values: true+.
      attr_accessor :result
      attr_reader :outcome, :error

      def initialize(backend:, locale:, key:, scope: nil)
        @backend = backend
        @locale = locale
        @key = key
        @scope = scope
        @events = []
        @children = []
        @outcome = nil
      end

      def finish(outcome, result: nil, error: nil, record_result: false)
        @outcome = outcome
        @result = result if record_result
        if error
          @error = { :class => error.class.name, :message => error.message }
        end
        self
      end

      def finished?
        !@outcome.nil?
      end

      def hit?
        @outcome == :hit
      end

      def missing?
        @outcome == :missing
      end

      def error?
        @outcome == :error
      end

      def backend_name
        backend.class.name || backend.class.inspect
      end

      def each_node(&block)
        return enum_for(:each_node) unless block_given?
        yield self
        children.each { |child| child.each_node(&block) }
      end

      def to_h
        hash = {
          :backend => backend_name,
          :locale => locale,
          :key => key,
          :outcome => outcome
        }
        hash[:scope] = scope if scope
        hash[:entry] = entry if hit? && !entry.nil?
        hash[:result] = result if hit? && !result.nil?
        hash[:error] = error if error
        hash[:events] = events.map(&:to_h) unless events.empty?
        hash[:children] = children.map(&:to_h) unless children.empty?
        hash
      end

      def inspect
        "#<#{self.class.name} #{backend_name} locale=#{locale.inspect} " \
          "key=#{key.inspect} outcome=#{outcome.inspect}>"
      end
      alias_method :to_s, :inspect
    end

    attr_reader :roots

    def initialize(include_values: false)
      @include_values = include_values
      @roots = []
      @stack = []
    end

    def include_values?
      @include_values
    end

    # Activates this trace for the duration of the block. Nested activations
    # restore the previously active trace when done.
    def trace
      previous = Trace.current
      Trace.current = self
      begin
        yield
      ensure
        Trace.current = previous
      end
    end

    # The first root node. For a single key lookup this is the node
    # representing the top-level backend call.
    def root
      roots.first
    end

    # All nodes in the trace, depth-first.
    def nodes
      roots.flat_map { |root| root.each_node.to_a }
    end

    # The node where the final translation was actually found: the deepest
    # hit node that has no hit descendants. Returns nil when nothing was
    # found.
    def final_hit
      hits = roots.filter_map { |root| deepest_hit(root) }
      hits.last
    end

    def to_h
      { :roots => roots.map(&:to_h) }
    end

    # Renders the trace as an indented tree, one line per node.
    def to_s
      lines = []
      roots.each { |root| render_node(root, 0, lines) }
      lines.join("\n")
    end

    def inspect
      "#<#{self.class.name} roots=#{roots.size} nodes=#{nodes.size}>"
    end

    # Records one backend translate call as a node. Internal use only: this
    # is called from the backend implementations themselves, so a node always
    # corresponds to a lookup that really happened.
    def trace_lookup(backend, locale, key, options) # :nodoc:
      node = Node.new(
        :backend => backend,
        :locale => locale,
        :key => key,
        :scope => options[:scope]
      )
      (@stack.empty? ? @roots : @stack.last.children) << node
      @stack.push(node)
      begin
        result = catch(:exception) do
          begin
            yield
          rescue ::Exception => exception
            node.finish(:error, :error => exception)
            raise
          end
        end
        case result
        when I18n::MissingTranslation
          node.finish(:missing, :error => result)
          throw(:exception, result)
        when ::Exception
          node.finish(:error, :error => result)
          throw(:exception, result)
        else
          node.finish(:hit, :result => result, :record_result => include_values?)
          result
        end
      ensure
        @stack.pop
      end
    end

    def record_event(type, data = EMPTY_HASH) # :nodoc:
      node = @stack.last
      return unless node
      data = data.reject { |key, _| SENSITIVE_DATA_KEYS.include?(key) } unless include_values?
      node.events << Event.new(type, data)
    end

    def record_entry(entry) # :nodoc:
      node = @stack.last
      node.entry = entry if node
    end

    class << self
      # The trace currently active on this fiber/thread, if any.
      def current
        entry = read_storage(:i18n_trace)
        entry && entry.first.equal?(Thread.current) ? entry.last : nil
      end

      def current=(trace) # :nodoc:
        # Fiber local variables are inherited by newly spawned threads, so
        # the owning thread is stored alongside the trace to keep concurrent
        # requests isolated from each other.
        write_storage(:i18n_trace, trace && [Thread.current, trace])
      end

      # The last trace completed through I18n.translate on this fiber/thread.
      def last
        entry = read_storage(:i18n_last_trace)
        entry && entry.first.equal?(Thread.current) ? entry.last : nil
      end

      def last=(trace) # :nodoc:
        write_storage(:i18n_last_trace, trace && [Thread.current, trace])
      end

      # Wraps one backend translate call. When no trace is active this simply
      # yields, so untraced calls are unaffected.
      def trace_lookup(backend, locale, key, options) # :nodoc:
        trace = current
        return yield unless trace
        trace.trace_lookup(backend, locale, key, options) { yield }
      end

      def record_event(type, data = EMPTY_HASH) # :nodoc:
        trace = current
        trace.record_event(type, data) if trace
      end

      def record_entry(entry) # :nodoc:
        trace = current
        trace.record_entry(entry) if trace
      end

      private

      def read_storage(key)
        if Fiber.respond_to?(:[])
          Fiber[key]
        else
          Thread.current.thread_variable_get(key)
        end
      end

      def write_storage(key, value)
        if Fiber.respond_to?(:[])
          Fiber[key] = value
        else
          Thread.current.thread_variable_set(key, value)
        end
      end
    end

    private

    def deepest_hit(node)
      return nil unless node.hit?
      node.children.reverse_each do |child|
        hit = deepest_hit(child)
        return hit if hit
      end
      node
    end

    def render_node(node, depth, lines)
      lines << "#{'  ' * depth}- #{node.backend_name} locale=#{node.locale.inspect} " \
        "key=#{node.key.inspect} => #{node.outcome}"
      node.children.each { |child| render_node(child, depth + 1, lines) }
    end
  end
end
