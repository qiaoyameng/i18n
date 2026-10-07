# frozen_string_literal: true

module I18n
  # Static analysis of Symbol aliases stored in a backend's translations.
  #
  # A translation whose value is a Symbol acts as an alias to another key
  # (e.g. <tt>{ :foo => :bar }</tt>). Cyclic or dangling aliases usually only
  # blow up at request time with a stack overflow or a missing translation.
  # The AliasChecker walks the alias graph reachable from a given locale and
  # namespace (scope) upfront and reports:
  #
  # * cycles        - aliases that (transitively) reference themselves,
  #                   including cycles spanning multiple locales through
  #                   locale fallbacks
  # * dangling      - aliases whose target key exists neither in the locale
  #                   nor in any of its fallback locales
  # * runtime       - Proc translations, which are resolved at runtime and
  #                   therefore cannot be analyzed statically. They are
  #                   reported (never called) and prevent the graph from
  #                   being declared clean.
  #
  # Key resolution follows the same rules as regular lookups: keys and
  # scopes are normalized with the configured separator and alias targets
  # are resolved through the locale fallback chain when the backend
  # includes I18n::Backend::Fallbacks. Keys living in different namespaces
  # are never merged; every node is identified by its locale and its full
  # key path.
  #
  # The analysis is read-only: it never translates, interpolates or
  # resolves keys through the backend, so stored translations and cached
  # values are left untouched.
  class AliasChecker
    # A cycle of aliases. +nodes+ holds the labels of the cycle members in
    # traversal order, +entries+ holds the full reference paths (starting at
    # keys inside the checked namespace) that lead into the cycle. A shared
    # cycle is reported only once, no matter how many keys reference it.
    Cycle = Struct.new(:nodes, :entries)

    # An alias whose target cannot be found. +path+ is the full reference
    # path from the checked namespace to the alias, +target+ is the label of
    # the missing key.
    DanglingTarget = Struct.new(:path, :target)

    # A Proc translation. Procs decide their value at runtime, so they are
    # reported instead of being called. +path+ is the full reference path
    # from the checked namespace to the Proc.
    RuntimeResolution = Struct.new(:path)

    # The result of an alias check. All collections are sorted to keep the
    # output stable across runs.
    class Report
      attr_reader :locale, :scope, :cycles, :dangling, :runtime

      def initialize(locale, scope, cycles, dangling, runtime)
        @locale   = locale
        @scope    = scope
        @cycles   = cycles
        @dangling = dangling
        @runtime  = runtime
      end

      # True only when no cycles and no dangling targets were found and no
      # Proc translations were encountered. A graph containing Procs can
      # never be declared clean, because their aliases are only resolved at
      # runtime.
      def clean?
        cycles.empty? && dangling.empty? && runtime.empty?
      end
    end

    def initialize(backend, locale, scope: nil, separator: nil)
      unless backend.respond_to?(:translations)
        raise NotImplementedError,
          "#{backend.class} does not expose its translations; " \
          'alias checking requires a Simple compatible backend'
      end

      @backend   = backend
      @locale    = locale.to_sym
      @separator = separator || I18n.default_separator
      @scope     = I18n.normalize_keys(nil, nil, scope, @separator)
    end

    def check
      @backend.eager_load! if @backend.respond_to?(:eager_load!)

      @colors   = {} # node => :gray (on the current path) or :black (fully analyzed)
      @leads_to = {} # node => { cycle key => path suffix from the node into the cycle }
      @cycles   = {} # canonical cycle key => Cycle
      @dangling = []
      @runtime  = []

      root, = resolve_target(@scope)
      collect_entries(root).each { |entry| walk_chain([entry], []) } if root

      Report.new(
        @locale,
        @scope,
        @cycles.values.sort_by(&:nodes),
        @dangling.sort_by(&:path),
        @runtime.sort_by(&:path)
      )
    end

    protected

    # Nodes are [locale, key segments] pairs.

    def locale_chain
      @locale_chain ||= begin
        if defined?(I18n::Backend::Fallbacks) && @backend.is_a?(I18n::Backend::Fallbacks)
          I18n.fallbacks[@locale].map(&:to_sym)
        else
          [@locale]
        end
      end
    end

    def store_for(locale)
      store = @backend.translations
      store[locale] if store.has_key?(locale)
    end

    def raw_value_at(node)
      locale, segments = node
      value = store_for(locale)
      segments.each do |segment|
        return nil unless value.is_a?(Hash) && value.has_key?(segment)
        value = value[segment]
      end
      value
    end

    def label(node)
      locale, segments = node
      "#{locale}:#{segments.join(@separator)}"
    end

    # Resolves key +segments+ the same way a lookup would: the first locale
    # of the fallback chain in which the full path exists wins, and aliases
    # encountered in the middle of the path are resolved before the
    # remaining segments. Returns [node, hops] where node is the resolved
    # [locale, segments] pair (nil when the target dangles) and hops lists
    # intermediate alias nodes crossed while resolving the path.
    def resolve_target(segments)
      hops = []
      seen = {}
      current = segments

      loop do
        # Resolution is deterministic, so repeating the same segments or
        # crossing the same intermediate alias twice means the aliases loop
        # (a lookup would overflow the stack here). Return the repeated hop
        # as the target and let the walker detect the cycle.
        return [hops.last, hops] if seen[current]
        seen[current] = true

        found = nil
        retry_with = false

        locale_chain.each do |locale|
          value = store_for(locale)
          next unless value.is_a?(Hash)

          node_segments = []
          hit_alias = false
          complete = true

          current.each_with_index do |segment, index|
            unless value.is_a?(Hash) && value.has_key?(segment)
              complete = false
              break
            end
            node_segments << segment
            value = value[segment]
            if value.is_a?(Symbol) && index < current.length - 1
              hit_alias = true
              break
            end
          end

          if hit_alias
            hop = [locale, node_segments]
            return [hop, hops] if hops.include?(hop)
            hops << hop
            current = I18n.normalize_keys(nil, value, nil, @separator) +
              current[node_segments.length..-1]
            retry_with = true
            break
          end

          if complete
            found = [locale, node_segments]
            break
          end
        end

        return [found, hops] unless retry_with
      end
    end

    # Collects the alias (Symbol) and runtime (Proc) leaves of the subtree
    # rooted at +node+, in a stable (sorted) order.
    def collect_entries(node)
      entries = []
      collect_into(node, raw_value_at(node), entries)
      entries
    end

    def collect_into(node, value, entries)
      case value
      when Hash
        value.keys.sort_by(&:to_s).each do |key|
          collect_into([node[0], node[1] + [key]], value[key], entries)
        end
      when Symbol, Proc
        entries << node
      end
    end

    # Walks a chain of nodes (an alias followed by the hops and target it
    # resolves to), expanding the last node. True cycles are detected via
    # the nodes currently on the path (:gray); nodes that were fully
    # analyzed before (:black) are not followed again, so legal diamond
    # dependencies are not mistaken for cycles.
    def walk_chain(nodes, path)
      return if nodes.empty?

      node, rest = nodes.first, nodes[1..-1]

      case @colors[node]
      when :gray
        index = path.index(node)
        record_cycle(path[index..-1], path[0..index])
      when :black
        record_entries_through(node, path)
        path.push(node)
        walk_chain(rest, path)
        path.pop
      else
        @colors[node] = :gray
        path.push(node)
        rest.empty? ? expand(node, path) : walk_chain(rest, path)
        path.pop
        @colors[node] = :black
      end
    end

    def expand(node, path)
      case (value = raw_value_at(node))
      when Symbol
        target, hops = resolve_target(I18n.normalize_keys(nil, value, nil, @separator))
        if target
          walk_chain(hops + [target], path)
        else
          record_dangling(path + hops, value)
        end
      when Proc
        # Procs are resolved at runtime; report them without calling them.
        @runtime << RuntimeResolution.new(path.map { |n| label(n) })
      end
    end

    def record_cycle(cycle_nodes, entrance_path)
      key = cycle_nodes.map { |node| label(node) }.sort
      cycle = (@cycles[key] ||= Cycle.new(cycle_nodes.map { |node| label(node) }, []))
      add_entry(cycle, entrance_path)
      propagate(key, entrance_path)
    end

    def record_entries_through(node, path)
      return unless @leads_to[node]

      @leads_to[node].each do |key, suffix|
        add_entry(@cycles[key], path + suffix)
        propagate(key, path + suffix)
      end
    end

    # Remembers, for every node on the entrance path, how it reaches the
    # cycle so that later references through already analyzed nodes still
    # get their entry reported.
    def propagate(key, entrance_path)
      entrance_path.each_with_index do |node, index|
        suffixes = (@leads_to[node] ||= {})
        suffixes[key] ||= entrance_path[index..-1]
      end
    end

    def add_entry(cycle, entry_nodes)
      entry = entry_nodes.map { |node| label(node) }
      cycle.entries << entry unless cycle.entries.include?(entry)
    end

    def record_dangling(path, target)
      target = I18n.normalize_keys(nil, target, nil, @separator)
      @dangling << DanglingTarget.new(
        path.map { |node| label(node) },
        "#{@locale}:#{target.join(@separator)}"
      )
    end
  end
end
