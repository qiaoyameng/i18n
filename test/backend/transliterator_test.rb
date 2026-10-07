# encoding: utf-8
require 'test_helper'

class I18nBackendTransliterator < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    @proc = lambda { |n| n.upcase }
    @hash = { "ü" => "ue", "ö" => "oe", "a" => "a" }
    @transliterator = I18n::Backend::Transliterator.get
  end

  test "transliteration rule can be a proc" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @proc}})
    assert_equal "HELLO", I18n.backend.transliterate(:xx, "hello")
  end

  test "transliteration rule can be a hash" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @hash}})
    assert_equal "ue", I18n.backend.transliterate(:xx, "ü")
  end

  test "transliteration rule must be a proc or hash" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => ""}})
    assert_raises I18n::ArgumentError do
      I18n.backend.transliterate(:xx, "ü")
    end
  end

  test "transliterator defaults to latin => ascii when no rule is given" do
    assert_equal "AEroskobing", I18n.backend.transliterate(:xx, "Ærøskøbing")
  end

  test "default transliterator should not modify ascii characters" do
    (0..127).each do |byte|
      char = [byte].pack("U")
      assert_equal char, @transliterator.transliterate(char)
    end
  end

  test "default transliterator correctly transliterates latin characters" do
    # create string with range of Unicode's western characters with
    # diacritics, excluding the division and multiplication signs which for
    # some reason or other are floating in the middle of all the letters.
    string = (0xC0..0x17E).to_a.reject {|c| [0xD7, 0xF7].include? c}.append(0x1E9E).pack("U*")
    string.split(//) do |char|
      assert_match %r{^[a-zA-Z']*$}, @transliterator.transliterate(string)
    end
  end

  test "should replace non-ASCII chars not in map with a replacement char" do
    assert_equal "abc?", @transliterator.transliterate("abcſ")
  end

  test "can replace non-ASCII chars not in map with a custom replacement string" do
    assert_equal "abc#", @transliterator.transliterate("abcſ", "#")
  end

  test "can keep non-ASCII chars not in map with :none" do
    assert_equal "abcſ", @transliterator.transliterate("abcſ", :none)
  end

  test "default transliterator raises errors for invalid UTF-8" do
    assert_raises ArgumentError do
      @transliterator.transliterate("a\x92b")
    end
  end

  test "I18n.transliterate should transliterate using a default transliterator" do
    assert_equal "aeo", I18n.transliterate("áèö")
  end

  test "I18n.transliterate should transliterate using a locale" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => @hash}})
    assert_equal "ue", I18n.transliterate("ü", :locale => :xx)
  end

  test "default transliterator fails with custom rules with uncomposed input" do
    char = [117, 776].pack("U*") # "ü" as ASCII "u" plus COMBINING DIAERESIS
    transliterator = I18n::Backend::Transliterator.get(@hash)
    refute_equal "ue", transliterator.transliterate(char)
  end

  test "DEFAULT_APPROXIMATIONS is frozen to prevent concurrency issues" do
    assert I18n::Backend::Transliterator::HashTransliterator::DEFAULT_APPROXIMATIONS.frozen?
  end

  test "multi-char mode matches the longest source fragment" do
    transliterator = I18n::Backend::Transliterator.get({"ch" => "x", "c" => "y", "h" => "z"}, :multi_char => true)
    assert_equal "x", transliterator.transliterate("ch")
    assert_equal "xy", transliterator.transliterate("chc")
  end

  test "multi-char mode lets a long rule shadow a shorter prefix rule" do
    transliterator = I18n::Backend::Transliterator.get({"ss" => "X", "s" => "Y"}, :multi_char => true)
    assert_equal "XY", transliterator.transliterate("sss")
  end

  test "multi-char mode leaves unmatched ASCII untouched" do
    transliterator = I18n::Backend::Transliterator.get({"Ǆ" => "J"}, :multi_char => true)
    assert_equal "aJb", transliterator.transliterate("aǄb")
  end

  test "multi-char mode replaces unmatched non-ASCII with the replacement char" do
    transliterator = I18n::Backend::Transliterator.get({"Ǆ" => "J"}, :multi_char => true)
    assert_equal "aJ?", transliterator.transliterate("aǄ日")
    assert_equal "aJ#", transliterator.transliterate("aǄ日", "#")
    assert_equal "aJ日", transliterator.transliterate("aǄ日", :none)
  end

  test "multi-char mode preserves an empty replacement string" do
    transliterator = I18n::Backend::Transliterator.get({"日" => ""}, :multi_char => true)
    assert_equal "ab", transliterator.transliterate("a日b")
  end

  test "multi-char mode does not re-match replacement output" do
    transliterator = I18n::Backend::Transliterator.get({"x" => "ch", "ch" => "!"}, :multi_char => true)
    assert_equal "ch", transliterator.transliterate("x")
  end

  test "multi-char mode accepts a frozen input string" do
    transliterator = I18n::Backend::Transliterator.get({"ǆ" => "j"}, :multi_char => true)
    assert_equal "ajb", transliterator.transliterate("aǆb".freeze)
  end

  test "multi-char mode supports supplementary plane source fragments" do
    transliterator = I18n::Backend::Transliterator.get({"𝕏" => "X"}, :multi_char => true)
    assert_equal "aXb", transliterator.transliterate("a𝕏b")
  end

  test "multi-char mode supports combining mark source fragments" do
    transliterator = I18n::Backend::Transliterator.get({"a\u0308" => "AE"}, :multi_char => true)
    assert_equal "xAEy", transliterator.transliterate("xa\u0308y")
  end

  test "multi-char matching does not scan every rule at each position" do
    rules = {}
    5000.times { |i| rules["prefix#{i}"] = "P#{i}" }
    rules["prefixX"] = "WIN"
    transliterator = I18n::Backend::Transliterator.get(rules, :multi_char => true)
    assert_equal "xxWINxx", transliterator.transliterate("xxprefixXxx")
  end

  test "array rules preserve explicit ordering in multi-char mode" do
    transliterator = I18n::Backend::Transliterator.get([["abc", "1"], ["ab", "2"]], :multi_char => true)
    assert_equal "12", transliterator.transliterate("abcab")
  end

  test "an empty rule key is rejected" do
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get({"" => "x"}, :multi_char => true)
    end
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get({"" => "x"})
    end
  end

  test "multi-char mode can be enabled by an embedded rule option" do
    transliterator = I18n::Backend::Transliterator.get({"ch" => "x", "c" => "y", :multi_char => true})
    assert_equal "xy", transliterator.transliterate("chc")
  end

  test "NFC normalization matches decomposed input against composed rules" do
    char = [117, 776].pack("U*") # "ü" as ASCII "u" plus COMBINING DIAERESIS
    transliterator = I18n::Backend::Transliterator.get({"ü" => "ue"}, :nfc => true)
    assert_equal "ue", transliterator.transliterate(char)
  end

  test "NFC normalization works together with multi-char mode" do
    transliterator = I18n::Backend::Transliterator.get({"sch" => "sh"}, :multi_char => true, :nfc => true)
    assert_equal "shnee", transliterator.transliterate("schnee")
  end

  test "without NFC normalization decomposed input keeps the default behavior" do
    char = [117, 776].pack("U*")
    transliterator = I18n::Backend::Transliterator.get({"ü" => "ue"})
    refute_equal "ue", transliterator.transliterate(char)
  end

  test "multi-char and NFC options can be loaded from translation data" do
    store_translations(:xx, :i18n => {:transliterate => {:rule => {"ch" => "x", "c" => "y", "multi_char" => true}}})
    assert_equal "xy", I18n.backend.transliterate(:xx, "chc")
  end

  test "switching locale immediately uses that locale's rules and mode" do
    store_translations(:de, :i18n => {:transliterate => {:rule => {"ü" => "ue", "multi_char" => true}}})
    store_translations(:fr, :i18n => {:transliterate => {:rule => {"ü" => "u"}}})
    assert_equal "ue", I18n.backend.transliterate(:de, "ü")
    assert_equal "u", I18n.backend.transliterate(:fr, "ü")
    assert_equal "ue", I18n.backend.transliterate(:de, "ü")
  end

end
