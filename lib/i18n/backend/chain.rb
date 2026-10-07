# frozen_string_literal: true

module I18n
  module Backend
    # Backend that chains multiple other backends and checks each of them when
    # a translation needs to be looked up. This is useful when you want to use
    # standard translations with a Simple backend but store custom application
    # translations in a database or other backends.
    #
    # To use the Chain backend instantiate it and set it to the I18n module.
    # You can add chained backends through the initializer or backends
    # accessor:
    #
    #   # preserves the existing Simple backend set to I18n.backend
    #   I18n.backend = I18n::Backend::Chain.new(I18n::Backend::ActiveRecord.new, I18n.backend)
    #
    # The implementation assumes that all backends added to the Chain implement
    # a lookup method with the same API as Simple backend does.
    #
    # Fallback translations using the :default option are only used by the last backend of a chain.
    class Chain
      module Implementation
        include Base

        attr_accessor :backends

        def initialize(*backends)
          self.backends = backends
        end

        def initialized?
          backends.all? do |backend|
            backend.instance_eval do
              return false unless initialized?
            end
          end
          true
        end

        def reload!
          backends.each { |backend| backend.reload! }
        end

        def eager_load!
          backends.each { |backend| backend.eager_load! }
        end

        def store_translations(locale, data, options = EMPTY_HASH)
          backends.first.store_translations(locale, data, options)
        end

        def available_locales
          backends.map { |backend| backend.available_locales }.flatten.uniq
        end

        def translate(locale, key, default_options = EMPTY_HASH)
          namespace = nil
          blocked = false
          options = Utils.except(default_options, :default)

          backends.each do |backend|
            thrown = catch(:exception) do
              is_last = backend == backends.last
              options = default_options if is_last
              translation = backend.translate(locale, key, options)
              if namespace_lookup?(translation, options)
                if is_last
                  namespace = _deep_merge(translation, namespace || {})
                else
                  # Translate prunes I18n::BLOCKED markers from the result, so
                  # merge the raw subtree (with markers) when the result is a
                  # plain namespace; other Hashes (e.g. Hash defaults that
                  # went through deep interpolation) are returned as-is.
                  subtree = raw_namespace(backend, locale, key, options)
                  if subtree.equal?(I18n::BLOCKED)
                    blocked = true
                    throw(:exception)
                  elsif subtree.is_a?(Hash)
                    namespace = _deep_merge(subtree, namespace || {})
                  else
                    return translation
                  end
                end
              elsif !translation.nil? || (options.key?(:default) && options[:default].nil?)
                return translation
              end
            end
            if thrown.is_a?(BlockedTranslation)
              blocked = true
              break
            end
          end

          return prune_blocked_entries(namespace) if namespace

          return if blocked && default_options.key?(:default) && default_options[:default].nil?

          if blocked
            default_subject = default_options[:default]
            if default_options.key?(:default)
              return nil if default_subject.nil?
              resolved = resolve_blocked_default(locale, key, default_subject, default_options)
              unless resolved.nil?
                values = Utils.except(default_options, *RESERVED_KEYS)
                resolved = interpolate(locale, resolved, values) unless values.empty?
                return resolved
              end
            end
            throw(:exception, BlockedTranslation.new(locale, key, default_options))
          end

          throw(:exception, I18n::MissingTranslation.new(locale, key, options))
        end

        def exists?(locale, key, options = EMPTY_HASH)
          backends.each do |backend|
            return false if backend.blocked?(locale, key, options)
            return true if backend.exists?(locale, key, options)
          end
          false
        end

        # True when the key is blocked by a backend earlier in the chain than
        # any backend that would still resolve it.
        def blocked?(locale, key, options = EMPTY_HASH)
          backends.each do |backend|
            return true if backend.blocked?(locale, key, options)
            result = catch(:exception) do
              backend.translate(locale, key, Utils.except(options, :default))
            end
            return false unless result.nil? || result.is_a?(MissingTranslation)
          end
          false
        end

        def localize(locale, object, format = :default, options = EMPTY_HASH)
          backends.each do |backend|
            catch(:exception) do
              result = backend.localize(locale, object, format, options) and return result
            end
          end
          throw(:exception, I18n::MissingTranslation.new(locale, format, options))
        end

        protected
          def init_translations
            backends.each do |backend|
              backend.send(:init_translations)
            end
          end

          def translations
            backends.reverse.each_with_object({}) do |backend, memo|
              partial_translations = backend.instance_eval do
                init_translations unless initialized?
                translations
              end
              Utils.deep_merge!(memo, partial_translations) { |_, a, b| b || a }
            end
          end

          def namespace_lookup?(result, options)
            result.is_a?(Hash) && !options.has_key?(:count)
          end

        private
          # Raw subtree for a namespace lookup, including I18n::BLOCKED
          # markers so that blocks from earlier backends can mask keys merged
          # in from lower backends. Backends without their own +lookup+ (such
          # as an inner Chain) fall back to the already-pruned translate
          # result.
          def raw_namespace(backend, locale, key, options)
            subtree = backend.blocked_lookup(locale, key, options)
            subtree.is_a?(Hash) || subtree.equal?(I18n::BLOCKED) ? subtree : {}
          end

          # This is approximately what gets used in ActiveSupport.
          # However since we are not guaranteed to run in an ActiveSupport context
          # it is wise to have our own copy. We underscore it
          # to not pollute the namespace of the including class.
          def _deep_merge(hash, other_hash)
            copy = hash.dup
            other_hash.each_pair do |k,v|
              value_from_other = hash[k]
              copy[k] = value_from_other.is_a?(Hash) && v.is_a?(Hash) ? _deep_merge(value_from_other, v) : v
            end
            copy
          end
      end

      include Implementation
    end
  end
end
