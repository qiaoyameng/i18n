# frozen_string_literal: true

module I18n
  # Per-call resolution tracing.
  #
  # A Trace collects exactly the lookups that happen while resolving a single
  # +I18n.translate+ call: which backends were consulted, which locales (and
  # fallback locales) were tried, which keys were requested, symbol alias
  # hops, Proc evaluations, default usage, pluralization branches and the
  # location of the translation that finally won.
  #
  # Tracing never re-executes anything. Entries are recorded around the calls
  # that already happen and closed with the value/exception those calls
  # actually produced. Return values, +false+/+nil+ semantics and Chain
  # ordering are unchanged.
  #
  # A Trace is activated for one call only, either through the +trace:+
  # option, +I18n.translate_with_trace+ or +I18n.with_trace+. The active
  # trace is kept in Fiber local storage, so concurrent requests and
  # untraced calls never share state.
  #
  #   result, trace = I18n.translate_with_trace(:'errors.messages.foo')
  #   trace.final.location # => { backend: "I18n::Backend::Simple", locale: :en, key: ... }
  #
  # Interpolation values passed by the caller are never stored.
  class Trace
    include Enumerable

    FIBER_KEY = :i18n_trace
    SUPPRESS_KEY = :i18n_trace_suppress

    # Entry kinds that can be the final hit location of a translation.
    TERMINAL_KINDS = %i[lookup backend cache default].freeze
    EMPTY_ATTRIBUTES = {}.freeze

    # The currently active trace for this Fiber, or nil.
    def self.current
      return nil if Fiber.respond_to?(:[]) ? Fiber[SUPPRESS_KEY] : Thread.current[SUPPRESS_KEY]

      if Fiber.respond_to?(:[])
        Fiber[FIBER_KEY]
      else
        Thread.current[FIBER_KEY]
      end
    end

    # Runs the block with +trace+ installed as the active trace. Restores the
    # previously active trace afterwards, so nested activation is safe.
    def self.activate(trace)
      if Fiber.respond_to?(:[])
        previous = Fiber[FIBER_KEY]
        Fiber[FIBER_KEY] = trace
        begin
          yield trace
        ensure
          Fiber[FIBER_KEY] = previous
        end
      else
        previous = Thread.current[FIBER_KEY]
        Thread.current[FIBER_KEY] = trace
        begin
          yield trace
        ensure
          Thread.current[FIBER_KEY] = previous
        end
      end
    end

    # Runs +block+ with tracing disabled, even inside an active trace.
    def self.suppress
      if Fiber.respond_to?(:[])
        previous = Fiber[SUPPRESS_KEY]
        Fiber[SUPPRESS_KEY] = true
        begin
          yield
        ensure
          Fiber[SUPPRESS_KEY] = previous
        end
      else
        previous = Thread.current[SUPPRESS_KEY]
        Thread.current[SUPPRESS_KEY] = true
        begin
          yield
        ensure
          Thread.current[SUPPRESS_KEY] = previous
        end
      end
    end

    # Annotates the entry currently being recorded, if any.
    def self.annotate(attributes)
      current&.annotate(attributes)
    end

    # Classifies a +:default+ option value without retaining Procs.
    def self.default_type(value)
      case value
      when Symbol then :symbol
      when Proc   then :proc
      when String then :string
      when Hash   then :hash
      when Array  then :array
      else value.class
      end
    end

    def self.backend_name(backend)
      name = backend_origin_name(backend)
      "#{name}##{backend.object_id}"
    rescue StandardError
      nil
    end

    # Uses the first named class/module in the backend's ancestor chain that
    # lives under I18n::Backend, so a subclass still reports the library
    # backend it is based on.
    def self.backend_origin_name(backend)
      klass = backend.class
      return klass.name if klass.name && klass.name.start_with?('I18n::Backend::')

      # Prefer a concrete backend class (Simple, KeyValue, Chain, ...) over
      # feature modules like Pluralization/Fallbacks.
      backend.class.ancestors.select { |ancestor| ancestor.is_a?(Class) }.each do |ancestor|
        name = ancestor.name
        next unless name
        return name if name.start_with?('I18n::Backend::')
      end
      backend.class.ancestors.each do |ancestor|
        name = ancestor.name
        next unless name
        return name if name.start_with?('I18n::Backend::')
      end
      klass.name
    end

    Entry = Struct.new(
      :id, :root_id, :parent_id, :depth, :kind,
      :backend, :locale, :original_locale, :key, :scope,
      :status, :error_class, :result_class, :result_value,
      :captured,
      :default, :default_type, :alias_key, :plural_key, :count,
      :fallback_index, :cache, :bulk, :winner_id
    ) do
      def initialize(*)
        super
        self.depth ||= 0
        @children = []
      end

      attr_accessor :children

      def root?
        id == root_id
      end

      def hit?
        status == :hit
      end

      def missing?
        status == :missing
      end

      def error?
        status == :error
      end

      def false_value?
        status == :false
      end

      def final?
        !!@final
      end

      def final!
        @final = true
      end

      def terminal?
        TERMINAL_KINDS.include?(kind)
      end

      # The backend/locale/key location this entry represents, or nil for
      # non-terminal entries.
      def location
        return nil unless terminal?

        { backend: backend, locale: locale, key: key, scope: scope }
      end

      def to_h
        hash = {}
        members.each do |member|
          value = public_send(member)
          hash[member] = value unless value.nil?
        end
        hash[:final] = true if final?
        hash[:children] = children.map(&:to_h) unless children.empty?
        hash
      end
      alias to_hash to_h

      def inspect
        "#<I18n::Trace::Entry id=#{id} kind=#{kind} status=#{status} " \
          "locale=#{locale.inspect} key=#{key.inspect}>"
      end
    end

    # By default the resolved translation value is recorded too. Pass
    # +capture_values: false+ to record value classes only. Interpolation
    # values supplied by the caller are never captured, regardless.
    def initialize(capture_values: true)
      @entries = []
      @stack = []
      @sequence = 0
      @root_count = 0
      @capture_values = capture_values
    end

    # All entries, in the (pre-order) sequence they were started.
    attr_reader :entries

    def each(&block)
      entries.each(&block)
    end

    def roots
      entries.select(&:root?)
    end

    # The root entry of the (last) top level translate call.
    def root
      roots.last
    end

    # Populates Entry#children and returns the root entries as a tree.
    def tree
      by_parent = Hash.new { |hash, parent_id| hash[parent_id] = [] }
      entries.each { |entry| entry.children.clear }
      entries.each do |entry|
        by_parent[entry.parent_id] << entry unless entry.root?
      end
      entries.each do |entry|
        entry.children.concat(by_parent[entry.id])
      end
      roots
    end

    # The entry that produced the final value of the (last) root call.
    def final
      winner_id = root&.winner_id
      entries.find { |entry| entry.id == winner_id } if winner_id
    end

    def hit?
      %i[hit false].include?(root&.status)
    end

    def missing?
      root&.missing?
    end

    def error?
      root&.error?
    end

    def attempts
      entries.select { |entry| %i[lookup backend fallback cache].include?(entry.kind) }
    end

    def defaults
      entries.select { |entry| entry.kind == :default }
    end

    def aliases
      entries.select { |entry| entry.kind == :alias }
    end

    def procs
      entries.select { |entry| entry.kind == :proc }
    end

    def pluralizations
      entries.select { |entry| entry.kind == :plural }
    end

    def errors
      entries.select(&:error?)
    end

    def misses
      entries.select(&:missing?)
    end

    # Records an entry around +block+. No-op behavior-wise when no trace is
    # active (callers check Trace.current, but this is also safe to call
    # unconditionally).
    def wrap(kind, attributes = EMPTY_ATTRIBUTES)
      entry = start_entry(kind, attributes)
      capture = attributes.fetch(:capture, true)
      entry.captured = capture
      result = nil
      caught = catch(:exception) do
        begin
          result = yield
        rescue MissingTranslation::Base => error
          entry.status = :missing
          entry.result_class = error.class
          raise
        rescue StandardError => error
          entry.status = :error
          entry.error_class = error.class
          raise
        end
      end

      if caught.is_a?(MissingTranslation)
        entry.status = :missing
        entry.result_class = caught.class
        # close_entry runs in ensure, but the rethrow below bypasses normal
        # return flow; finalize the entry explicitly so the winning value is
        # not overwritten with a stale local.
        finalize_closed_entry(entry)
        throw(:exception, caught)
      end

      caught
    ensure
      close_entry(entry, result.nil? ? caught : result) unless entry.status == :missing
    end

    def finalize_closed_entry(entry)
      @stack.pop if @stack.last == entry
      finalize_root(entry) if entry.root? && entry.id == entry.root_id
    end

    def annotate(attributes)
      @stack.last&.tap do |entry|
        attributes.each do |name, value|
          entry.public_send(:"#{name}=", value) if entry.respond_to?(:"#{name}=")
        end
      end
    end

    # The entry currently being recorded.
    def last_entry
      @stack.last
    end

    # Marks every open entry as non-capturing. Used right before values are
    # interpolated, so caller supplied values never leak into ancestor
    # entries that would otherwise retain the post-interpolation string.
    def suppress_value_capture!
      @stack.each { |entry| entry.captured = false }
    end

    # Used by the facade when a MissingTranslation was handled by the
    # configured exception handler instead of being thrown.
    def mark_handled_missing(exception)
      entry = @stack.last
      return unless entry

      entry.status = :missing
      entry.result_class = exception.class
      entry
    end

    private

    def start_entry(kind, attributes)
      @sequence += 1
      parent = @stack.last
      entry = Entry.new
      entry.id = @sequence
      entry.kind = kind
      entry.depth = parent ? parent.depth + 1 : 0
      entry.parent_id = parent&.id
      entry.root_id = parent&.root_id || begin
        @root_count += 1
        @sequence
      end
      attributes.each do |name, value|
        entry.public_send(:"#{name}=", value) if entry.respond_to?(:"#{name}=")
      end
      @entries << entry
      @stack.push(entry)
      entry
    end

    def close_entry(entry, result)
      return unless entry
      @stack.pop if @stack.last == entry

      if entry.status.nil?
        entry.status = status_for(result)
        entry.result_class = result.class
      end

      if @capture_values && entry.captured != false && capturable?(result)
        entry.result_value = result
      end

      finalize_root(entry) if entry.root? && entry.id == entry.root_id
    end

    def status_for(result)
      case result
      when nil then :nil
      when false then :false
      when MissingTranslation then :missing
      else :hit
      end
    end

    def capturable?(result)
      return false if result.nil? || result.is_a?(Proc) || result.is_a?(MissingTranslation)

      true
    end

    def finalize_root(root_entry)
      winner = @entries.select do |entry|
        entry.root_id == root_entry.id &&
          entry.terminal? &&
          (entry.status == :hit || entry.status == :false)
      end.max_by(&:id)

      if winner
        winner.final!
        root_entry.winner_id = winner.id
      end
    end
  end
end
