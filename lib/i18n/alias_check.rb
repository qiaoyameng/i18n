# frozen_string_literal: true

module I18n
  class AliasCheck
    Node = Struct.new(:kind, :locale, :path, :value, keyword_init: true) do
      def id
        [kind, locale, path]
      end
    end

    CYCLE = :cycle

    def self.run(backend, locale, namespace = nil, scope: nil, separator: nil, fallback: true)
      namespace = scope if namespace.nil?
      new(backend, locale, namespace, separator, fallback).run
    end

    def initialize(backend, locale, namespace, separator, fallback)
      @backend = backend
      @locale = locale.to_sym
      @separator = separator || I18n.default_separator
      @fallback = fallback
      @translations = backend.alias_check_translations
      @namespace = normalize_parts(namespace)

      @colors = {}
      @edges = {}
      @nodes = {}
      @resolved_physical = {}
      @path = []
      @cycles = {}
      @dangling = {}
      @runtime_decisions = {}
      @cycle_occurred = false
    end

    def run
      entry_paths.each { |path| visit_lookup(@locale, path) }
      build_report
    end

    private

      def entry_paths
        paths = {}
        expanded = {}
        queue = []

        fallback_locales.each do |locale|
          collect_leaf_paths(raw_subtree(locale, @namespace), @namespace, paths)
        end

        paths.each_key { |path| queue << path }

        until queue.empty?
          path = queue.shift
          physical = resolve_for_expansion(@locale, path, @locale)
          next if physical.nil? || physical == CYCLE
          next unless physical.value.is_a?(Hash)

          collect_expanded_leaf_paths(physical, path, expanded) do |expanded_path|
            unless paths.key?(expanded_path) || expanded.key?(expanded_path) || queue.include?(expanded_path)
              queue << expanded_path
            end
          end
        end

        (paths.keys + expanded.keys).sort.uniq
      end

      def collect_leaf_paths(value, path, paths)
        if value.is_a?(Hash)
          sorted_keys(value).each do |key|
            collect_leaf_paths(value[key], path + [normalize_raw_key(key)], paths)
          end
        else
          paths[path] = true
        end
      end

      def collect_expanded_leaf_paths(physical, source_path, paths)
        target_path = physical.path
        value = raw_subtree(physical.locale, target_path)

        walk = lambda do |current_value, current_target, current_source|
          if current_value.is_a?(Hash)
            sorted_keys(current_value).each do |key|
              normalized_key = normalize_raw_key(key)
              next_target = current_target + [normalized_key]
              next_source = current_source + [normalized_key]
              walk.call(current_value[key], next_target, next_source)
            end
          else
            paths[current_source] = true
            yield current_source
          end
        end

        walk.call(value, target_path, source_path)
      end

      def visit_lookup(locale, path, original_locale = locale)
        node = Node.new(:kind => :lookup, :locale => locale, :path => path, :value => nil)
        previous_cycle_state = @cycle_occurred
        @cycle_occurred = false
        visit_node(node) do
          physical = resolve_lookup(locale, path, original_locale)
          if physical == CYCLE
            # The cycle was recorded while resolving the lookup.
          elsif physical
            add_edge(node, physical)
          else
            record_dangling(node)
          end
        end

        if @cycle_occurred || cyclic_node?(node)
          CYCLE
        else
          @resolved_physical[[locale, path, original_locale]]
        end
      ensure
        @cycle_occurred = previous_cycle_state
      end

      def visit_physical(node)
        value = node.value

        result = case value
        when Symbol
          target = Node.new(
            :kind => :lookup,
            :locale => @path.first.locale,
            :path => normalize_parts(value),
            :value => nil
          )
          add_edge(node, target)
        when Proc
          record_runtime(node)
        when Hash
          expanded_physical_leaves(node).each { |target| add_edge(node, target) }
        end
        result
      end

      def visit_node(node)
        id = node.id
        @nodes[id] = node
        case color(id)
        when :gray
          record_cycle(node)
          return CYCLE
        when :black
          return CYCLE if node.kind == :lookup && cyclic_node?(node)
          return @resolved_physical[[node.locale, node.path, node.locale]] if node.kind == :lookup
        end

        @colors[id] = :gray
        @path << node
        result = yield
        @path.pop
        @colors[id] = :black
        result
      end

      def resolve_lookup(locale, path, original_locale)
        key = [locale, path, original_locale]
        return @resolved_physical[key] if @resolved_physical.key?(key)

        fallback_locales_for(locale).each do |fallback_locale|
          result = resolve_in_locale(fallback_locale, path, original_locale)
          next if result.nil?

          @resolved_physical[key] = result
          return result
        end

        @resolved_physical[key] = nil
      end

      def resolve_for_expansion(locale, path, original_locale, seen = {})
        key = [locale, path, original_locale]
        return nil if seen[key]
        seen[key] = true

        fallback_locales_for(locale).each do |fallback_locale|
          value = @translations[fallback_locale]
          matched = true

          path.each_with_index do |raw_key, index|
            unless value.is_a?(Hash) && hash_key?(value, raw_key)
              matched = false
              break
            end

            value = value[fetch_hash_key(value, raw_key)]

            if value.is_a?(Symbol)
              target_path = normalize_parts(value) + path[(index + 1)..]
              resolved = resolve_for_expansion(original_locale, target_path, original_locale, seen)
              return resolved if resolved
              break
            end
          end

          next unless matched && !value.nil? && !value.is_a?(Symbol)
          return Node.new(:kind => :physical, :locale => fallback_locale, :path => path, :value => value)
        end

        nil
      end

      def resolve_in_locale(fallback_locale, path, original_locale)
        value = @translations[fallback_locale]
        matched = true

        path.each_with_index do |key, index|
          unless value.is_a?(Hash) && hash_key?(value, key)
            matched = false
            break
          end

          value = value[fetch_hash_key(value, key)]
          prefix = path[0..index]

          if value.is_a?(Symbol)
            symbol_physical = Node.new(
              :kind => :physical,
              :locale => fallback_locale,
              :path => prefix,
              :value => value
            )
            add_edge(@path.last, symbol_physical)
            return symbol_physical
          end
        end

        if matched && !value.nil?
          Node.new(:kind => :physical, :locale => fallback_locale, :path => path, :value => value)
        end
      end

      def expanded_physical_leaves(hash_node)
        leaves = []
        walk = lambda do |value, path|
          if value.is_a?(Hash)
            sorted_keys(value).each do |key|
              normalized_key = normalize_raw_key(key)
              walk.call(value[key], path + [normalized_key])
            end
          else
            leaves << Node.new(:kind => :physical, :locale => hash_node.locale, :path => path, :value => value)
          end
        end
        walk.call(hash_node.value, hash_node.path)
        leaves
      end

      def add_edge(from, to)
        edges(from.id) << to.id unless edges(from.id).include?(to.id)
        result = visit_node(to) do
          if to.kind == :lookup
            physical = resolve_lookup(to.locale, to.path, entry_original_locale(to))
            if physical == CYCLE
              # The cycle was recorded while resolving the lookup.
            elsif physical
              add_edge(to, physical)
            else
              record_dangling(to)
            end
          else
            visit_physical(to)
          end
        end
        result
      end

      def entry_original_locale(node)
        @path.first&.locale || node.locale
      end

      def record_cycle(back_to)
        @cycle_occurred = true
        index = @path.index { |node| node.id == back_to.id }
        cycle_nodes = @path[index..]
        cycle_path = simplify_path(cycle_nodes.map { |node| reference(node) } + [reference(back_to)], :closure => true)
        canonical = canonicalize(cycle_path[0..-2])

        @cycles[canonical] ||= {
          :canonical => canonical,
          :nodes => cycle_nodes.map(&:id)
        }
      end

      def record_dangling(node)
        @dangling[node.id] ||= { :node => node, :paths => [] }
      end

      def record_runtime(node)
        @runtime_decisions[node.id] ||= { :node => node, :paths => [] }
      end

      def build_report
        root_ids = entry_paths.map { |path| [:lookup, @locale, path] }

        {
          :cycles => @cycles.values.sort_by { |issue| issue[:canonical].map(&:to_a) }.map do |issue|
            {
              :cycle => issue[:canonical] + [issue[:canonical].first],
              :entries => cycle_entries(root_ids, issue[:canonical]).sort.uniq
            }
          end,
          :dangling => @dangling.values.sort_by { |issue| reference(issue[:node]).to_a }.map do |issue|
            {
              :target => reference(issue[:node]),
              :paths => paths_to(root_ids, issue[:node].id)
            }
          end,
          :runtime_decisions => @runtime_decisions.values.sort_by { |issue| reference(issue[:node]).to_a }.map do |issue|
            {
              :key => reference(issue[:node]),
              :paths => paths_to(root_ids, issue[:node].id)
            }
          end
        }
      end

      def cycle_entries(root_ids, canonical)
        cycle_references = canonical
        target_ids = cycle_references.map do |ref|
          [:lookup, ref.first, lookup_path(ref.last)]
        end

        entries = []
        root_ids.each do |root_id|
          walk_report_edges(root_id, target_ids, []) do |hit_id, prefix|
            next unless @nodes[hit_id].kind == :lookup

            hit_reference = reference(@nodes[hit_id])
            index = canonical.index(hit_reference)
            next unless index

            rotated = canonical.rotate(index)
            entries << simplify_path(prefix + rotated + [rotated.first], :closure => true)
          end
        end
        entries
      end

      def paths_to(root_ids, target_id)
        paths = []
        root_ids.each do |root_id|
          walk_report_edges(root_id, [target_id], []) do |hit_id, prefix|
            paths << prefix if hit_id == target_id
          end
        end
        paths.uniq
      end

      def walk_report_edges(id, target_ids, visited, &block)
        return if visited.include?(id)

        node = @nodes[id]
        return unless node

        node_ids = visited + [id]
        prefix = simplify_report_path(node_ids.map { |node_id| reference(@nodes[node_id]) }, node_ids)
        if target_ids.include?(id)
          yield(id, prefix)
          return
        end

        next_visited = visited + [id]
        edges(id).each do |edge_id|
          walk_report_edges(edge_id, target_ids, next_visited, &block)
        end
      end

      def lookup_path(key)
        normalize_parts(key)
      end

      def simplify_report_path(path, node_ids)
        path.each_with_index.with_object([]) do |(item, index), result|
          previous = index.zero? ? nil : @nodes[node_ids[index - 1]]
          current = @nodes[node_ids[index]]
          duplicate = result.last == item && previous&.kind == :lookup && current&.kind == :physical
          result << item unless duplicate
        end
      end

      def canonicalize(nodes)
        candidates = (0...nodes.size).map { |index| nodes.rotate(index) }
        candidates.min_by { |candidate| candidate.map(&:to_a) }
      end

      def cyclic_node?(node)
        @cycles.values.any? { |issue| issue[:nodes].include?(node.id) }
      end

      def edges(id)
        @edges[id] ||= []
      end

      def color(id)
        @colors[id] ||= :white
      end

      def reference(node)
        [node.locale, path_to_key(node.path)]
      end

      def simplify_path(path, closure: false)
        result = path.each_with_object([]) do |item, items|
          items << item unless items.last == item
        end
        result << result.first if closure && result.one?
        result
      end

      def path_to_key(path)
        path.map(&:to_s).join(@separator).to_sym
      end

      def raw_subtree(locale, path)
        dig_raw(@translations[locale], path)
      end

      def dig_raw(value, path)
        path.each do |key|
          return nil unless value.is_a?(Hash) && hash_key?(value, key)
          value = value[fetch_hash_key(value, key)]
        end
        value
      end

      def hash_key?(hash, key)
        hash.key?(key) || hash.key?(key.to_s.to_sym)
      end

      def fetch_hash_key(hash, key)
        hash.key?(key) ? key : key.to_s.to_sym
      end

      def sorted_keys(hash)
        hash.keys.sort_by { |key| [key.class.name.to_s, key.to_s] }
      end

      def normalize_parts(key)
        I18n.normalize_keys(nil, key, nil, @separator)
      end

      def normalize_raw_key(key)
        case key
        when Symbol, Integer, true, false
          key
        else
          key.to_s.to_sym
        end
      end

      def fallback_locales
        fallback_locales_for(@locale)
      end

      def fallback_locales_for(locale)
        return [locale] unless use_fallbacks?
        I18n.fallbacks[locale].to_a
      rescue I18n::InvalidLocale
        [locale]
      end

      def use_fallbacks?
        return false unless @fallback && I18n.respond_to?(:fallbacks)
        if @backend.is_a?(I18n::Backend::Chain)
          @backend.backends.any? { |backend| backend.is_a?(I18n::Backend::Fallbacks) }
        else
          @backend.is_a?(I18n::Backend::Fallbacks)
        end
      end
  end
end
