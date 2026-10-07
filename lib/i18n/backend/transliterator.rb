# encoding: utf-8
# frozen_string_literal: true

module I18n
  module Backend
    module Transliterator
      DEFAULT_REPLACEMENT_CHAR = "?"

      # Given a locale and a UTF-8 string, return the locale's ASCII
      # approximation for the string.
      def transliterate(locale, string, replacement = nil, nfc = nil)
        @transliterators ||= {}
        @transliterators[[locale, nfc]] ||= Transliterator.get(
          I18n.t(:'i18n.transliterate.rule',
            :locale => locale, :resolve => false, :default => {}),
          :nfc => nfc
        )
        @transliterators[[locale, nfc]].transliterate(string, replacement)
      end

      # Get a transliterator instance.
      def self.get(rule = nil, nfc: nil)
        if !rule || rule.kind_of?(Hash)
          HashTransliterator.new(rule, :nfc => nfc)
        elsif rule.kind_of? Proc
          ProcTransliterator.new(rule)
        else
          raise I18n::ArgumentError, "Transliteration rule must be a proc or a hash."
        end
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
        # Rule hash key which, when set to a truthy value, makes the
        # transliterator NFC-normalize both the rules and the input. This
        # allows decomposed sequences (e.g. "u" + COMBINING DIAERESIS) to match
        # their composed equivalents.
        NFC_OPTION_KEY = "i18n:nfc"

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

        def initialize(rule = nil, nfc: nil)
          @trie = RuleTrie.new
          @nfc = nfc.nil? ? nfc_option(rule) : nfc
          add(rule) if rule
          add_default_approximations
        end

        def transliterate(string, replacement = nil)
          replacement ||= DEFAULT_REPLACEMENT_CHAR
          input = @nfc ? string.unicode_normalize(:nfc) : string
          # Raise ArgumentError for invalid UTF-8, like a UTF-8 regex match does.
          input.unpack("U*")

          chars = input.each_char.to_a
          output = String.new
          index = 0

          while index < chars.length
            value, length = @trie.match(chars, index)

            if value
              output << value
              index += length
            else
              char = chars[index]
              if char.ascii_only? || replacement == :none
                output << char
              else
                output << replacement
              end
              index += 1
            end
          end

          output
        end

        private

        # Add transliteration rules to the trie. They are inserted before the
        # default approximations (see #add_default_approximations), so an
        # explicit rule always shadows a default one and the first rule wins
        # when several keys normalize to the same NFC sequence.
        def add(hash)
          hash.each do |key, value|
            next if option_key?(key)
            normalized_key = normalize_key(key)
            if normalized_key.empty?
              raise I18n::ArgumentError, "Transliteration rule keys cannot be empty."
            end
            @trie.add(normalized_key, value.to_s)
          end
        end

        def add_default_approximations
          DEFAULT_APPROXIMATIONS.each do |key, value|
            @trie.add(key, value)
          end
        end

        def normalize_key(key)
          normalized_key = key.to_s
          @nfc ? normalized_key.unicode_normalize(:nfc) : normalized_key
        end

        def nfc_option(hash)
          return false unless hash.kind_of?(Hash)
          hash.each do |key, value|
            return value if option_key?(key)
          end
          false
        end

        def option_key?(key)
          key.is_a?(Symbol) || key.is_a?(String) ? key.to_s == NFC_OPTION_KEY : false
        end

        # A trie of rule source fragments. Matching walks the longest path
        # whose node carries a replacement, so transliterating one position
        # never scans the whole rule set.
        class RuleTrie
          class Node
            def initialize
              @children = nil
              @value = nil
            end

            def [](char)
              @children && @children[char]
            end

            def []=(char, node)
              (@children ||= {})[char] = node
            end

            attr_accessor :value
          end

          def initialize
            @root = Node.new
          end

          # Insert the first replacement registered for a fragment.
          def add(fragment, replacement)
            node = @root
            fragment.each_char do |char|
              node = (node[char] ||= Node.new)
            end
            node.value ||= replacement
          end

          # Return [replacement, matched_character_count] for the longest
          # fragment starting at +index+, or [nil, 0] when nothing matches.
          def match(chars, index)
            node = @root
            replacement = nil
            matched_length = 0
            scan = index

            while scan < chars.length
              child = node[chars[scan]]
              break unless child
              node = child
              scan += 1
              if node.value
                replacement = node.value
                matched_length = scan - index
              end
            end

            [replacement, matched_length]
          end
        end
      end
    end
  end
end
