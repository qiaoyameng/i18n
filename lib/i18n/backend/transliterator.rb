# encoding: utf-8
# frozen_string_literal: true

module I18n
  module Backend
    module Transliterator
      DEFAULT_REPLACEMENT_CHAR = "?"

      # Keys which configure a transliterator instead of defining a rule.
      # Both symbol and string forms are accepted so that the configuration
      # can be supplied from Ruby code or loaded from translation data.
      MULTI_CHAR_OPTION_KEYS = [:multi_char, :multi_character, :longest_match,
                                "multi_char", "multi_character", "longest_match"].freeze
      NFC_OPTION_KEYS = [:nfc, :nfc_normalize, "nfc", "nfc_normalize"].freeze

      # Given a locale and a UTF-8 string, return the locale's ASCII
      # approximation for the string.
      def transliterate(locale, string, replacement = nil, multi_char = nil, nfc = nil)
        @transliterators ||= {}

        rule = I18n.t(:'i18n.transliterate.rule',
          :locale => locale, :resolve => false, :default => {})

        embedded = Transliterator.embedded_options(rule)
        multi_char = embedded[:multi_char] if multi_char.nil?
        nfc = embedded[:nfc] if nfc.nil?

        cache_key = [locale, !!multi_char, !!nfc]
        @transliterators[cache_key] ||=
          Transliterator.get(rule, :multi_char => multi_char, :nfc => nfc)
        @transliterators[cache_key].transliterate(string, replacement)
      end

      # Get a transliterator instance.
      def self.get(rule = nil, multi_char: nil, nfc: nil)
        if !rule || rule.kind_of?(Hash) || rule.kind_of?(Array)
          HashTransliterator.new(rule, :multi_char => multi_char, :nfc => nfc)
        elsif rule.kind_of? Proc
          ProcTransliterator.new(rule)
        else
          raise I18n::ArgumentError, "Transliteration rule must be a proc or a hash."
        end
      end

      # Extract transliterator configuration embedded in a rule collection.
      def self.embedded_options(rule)
        options = {:multi_char => nil, :nfc => nil}
        entries = rule.kind_of?(Array) ? rule : (rule.kind_of?(Hash) ? rule.each_pair : [])
        entries.each do |key, value|
          if MULTI_CHAR_OPTION_KEYS.include?(key)
            options[:multi_char] = value
          elsif NFC_OPTION_KEYS.include?(key)
            options[:nfc] = value
          end
        end
        options
      end

      # A transliterator which accepts a Proc as its transliteration rule.
      class ProcTransliterator
        def initialize(rule)
          @rule = rule
        end

        def transliterate(string, replacement = nil)
          @rule.call(string)
        end
      end

      # A transliterator which accepts a Hash of characters as its translation
      # rule.
      class HashTransliterator
        DEFAULT_APPROXIMATIONS = {
          "À"=>"A", "Á"=>"A", "Â"=>"A", "Ã"=>"A", "Ä"=>"A", "Å"=>"A", "Æ"=>"AE",
          "Ç"=>"C", "È"=>"E", "É"=>"E", "Ê"=>"E", "Ë"=>"E", "Ì"=>"I", "Í"=>"I",
          "Î"=>"I", "Ï"=>"I", "Ð"=>"D", "Ñ"=>"N", "Ò"=>"O", "Ó"=>"O", "Ô"=>"O",
          "Õ"=>"O", "Ö"=>"O", "×"=>"x", "Ø"=>"O", "Ù"=>"U", "Ú"=>"U", "Û"=>"U",
          "Ü"=>"U", "Ý"=>"Y", "Þ"=>"Th", "ß"=>"ss", "ẞ"=>"SS", "à"=>"a",
          "á"=>"a", "â"=>"a", "ã"=>"a", "ä"=>"a", "å"=>"a", "æ"=>"ae", "ç"=>"c",
          "è"=>"e", "é"=>"e", "ê"=>"e", "ë"=>"e", "ì"=>"i", "í"=>"i", "î"=>"i",
          "ï"=>"i", "ð"=>"d", "ñ"=>"n", "ò"=>"o", "ó"=>"o", "ô"=>"o", "õ"=>"o",
          "ö"=>"o", "ø"=>"o", "ù"=>"u", "ú"=>"u", "û"=>"u", "ü"=>"u", "ý"=>"y",
          "þ"=>"th", "ÿ"=>"y", "Ā"=>"A", "ā"=>"a", "Ă"=>"A", "ă"=>"a", "Ą"=>"A",
          "ą"=>"a", "Ć"=>"C", "ć"=>"c", "Ĉ"=>"C", "ĉ"=>"c", "Ċ"=>"C", "ċ"=>"c",
          "Č"=>"C", "č"=>"c", "Ď"=>"D", "ď"=>"d", "Đ"=>"D", "đ"=>"d", "Ē"=>"E",
          "ē"=>"e", "Ĕ"=>"E", "ĕ"=>"e", "Ė"=>"E", "ė"=>"e", "Ę"=>"E", "ę"=>"e",
          "Ě"=>"E", "ě"=>"e", "Ĝ"=>"G", "ĝ"=>"g", "Ğ"=>"G", "ğ"=>"g", "Ġ"=>"G",
          "ġ"=>"g", "Ģ"=>"G", "ģ"=>"g", "Ĥ"=>"H", "ĥ"=>"h", "Ħ"=>"H", "ħ"=>"h",
          "Ĩ"=>"I", "ĩ"=>"i", "Ī"=>"I", "ī"=>"i", "Ĭ"=>"I", "ĭ"=>"i", "Į"=>"I",
          "į"=>"i", "İ"=>"I", "ı"=>"i", "Ĳ"=>"IJ", "ĳ"=>"ij", "Ĵ"=>"J", "ĵ"=>"j",
          "Ķ"=>"K", "ķ"=>"k", "ĸ"=>"k", "Ĺ"=>"L", "ĺ"=>"l", "Ļ"=>"L", "ļ"=>"l",
          "Ľ"=>"L", "ľ"=>"l", "Ŀ"=>"L", "ŀ"=>"l", "Ł"=>"L", "ł"=>"l", "Ń"=>"N",
          "ń"=>"n", "Ņ"=>"N", "ņ"=>"n", "Ň"=>"N", "ň"=>"n", "ŉ"=>"'n", "Ŋ"=>"NG",
          "ŋ"=>"ng", "Ō"=>"O", "ō"=>"o", "Ŏ"=>"O", "ŏ"=>"o", "Ő"=>"O", "ő"=>"o",
          "Œ"=>"OE", "œ"=>"oe", "Ŕ"=>"R", "ŕ"=>"r", "Ŗ"=>"R", "ŗ"=>"r", "Ř"=>"R",
          "ř"=>"r", "Ś"=>"S", "ś"=>"s", "Ŝ"=>"S", "ŝ"=>"s", "Ş"=>"S", "ş"=>"s",
          "Š"=>"S", "š"=>"s", "Ţ"=>"T", "ţ"=>"t", "Ť"=>"T", "ť"=>"t", "Ŧ"=>"T",
          "ŧ"=>"t", "Ũ"=>"U", "ũ"=>"u", "Ū"=>"U", "ū"=>"u", "Ŭ"=>"U", "ŭ"=>"u",
          "Ů"=>"U", "ů"=>"u", "Ű"=>"U", "ű"=>"u", "Ų"=>"U", "ų"=>"u", "Ŵ"=>"W",
          "ŵ"=>"w", "Ŷ"=>"Y", "ŷ"=>"y", "Ÿ"=>"Y", "Ź"=>"Z", "ź"=>"z", "Ż"=>"Z",
          "ż"=>"z", "Ž"=>"Z", "ž"=>"z", "Ǫ"=>"O", "ǫ"=>"o", "Ǭ"=>"O",
          "ǭ"=>"o"
        }.freeze

        UNSET = Object.new.freeze

        def initialize(rule = nil, multi_char: nil, nfc: nil)
          entries = rule.kind_of?(Array) ? rule.to_a : (rule ? rule.each_pair.to_a : [])

          embedded_multi_char = nil
          embedded_nfc = nil
          rule_entries = []
          entries.each do |key, value|
            if Transliterator::MULTI_CHAR_OPTION_KEYS.include?(key)
              embedded_multi_char = value
            elsif Transliterator::NFC_OPTION_KEYS.include?(key)
              embedded_nfc = value
            else
              rule_entries << [key, value]
            end
          end

          @multi_char = multi_char.nil? ? !!embedded_multi_char : !!multi_char
          @nfc = nfc.nil? ? !!embedded_nfc : !!nfc

          add_default_approximations
          rule_entries.each { |key, value| store(key, value) }
        end

        def transliterate(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          string = string.unicode_normalize(:nfc) if @nfc
          return transliterate_multi_char(string, replacement) if @multi_char
          string.gsub(/[^\x00-\x7f]/u) do |char|
            approximations[char] || (replacement == :none ? char : replacement)
          end
        end

        private

        def transliterate_multi_char(string, replacement)
          chars = string.each_char.to_a
          result = String.new
          index = 0

          while index < chars.length
            matched_value, matched_length = longest_match(chars, index)

            if matched_length > 0
              result << matched_value
              index += matched_length
            else
              char = chars[index]
              result << if char.ord < 0x80 || replacement == :none
                          char
                        else
                          replacement
                        end
              index += 1
            end
          end

          result
        end

        # Walk the rule trie from the given position and return the value of
        # the deepest (longest) terminal node reached. At most the maximum
        # rule length is visited, so the cost never depends on the total
        # number of rules.
        def longest_match(chars, index)
          node = trie
          matched_value = UNSET
          matched_length = 0

          max_rule_length.times do |offset|
            char = chars[index + offset]
            break if char.nil?
            node = node[:children][char]
            break if node.nil?
            if node.key?(:value)
              matched_value = node[:value]
              matched_length = offset + 1
            end
          end

          matched_length > 0 ? [matched_value, matched_length] : [nil, 0]
        end

        # Trie of all rules. Keys are normalized the same way as the input so
        # that composed and decomposed forms are treated as the same source.
        def trie
          @trie ||= build_trie
        end

        def max_rule_length
          @max_rule_length ||= approximations.keys.map { |key| key.each_char.to_a.length }.max || 0
        end

        def build_trie
          root = {:children => {}}
          approximations.each do |key, value|
            node = root
            key.each_char do |char|
              node[:children][char] ||= {:children => {}}
              node = node[:children][char]
            end
            node[:value] = value
          end
          root
        end

        def approximations
          @approximations ||= {}
        end

        def add_default_approximations
          DEFAULT_APPROXIMATIONS.each do |key, value|
            approximations[normalize_key(key)] = value
          end
        end

        def store(key, value)
          source = normalize_key(key.to_s)
          if source.empty?
            raise I18n::ArgumentError, "Transliteration rules must not contain an empty key."
          end
          approximations[source] = value.to_s
        end

        def normalize_key(key)
          @nfc ? key.unicode_normalize(:nfc) : key
        end
      end
    end
  end
end
