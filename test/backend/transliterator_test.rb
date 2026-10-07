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

  test "multi-character rules are transliterated as one fragment" do
    rule = { "ch" => "kh", "ss" => "sz", "ü" => "ue" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "khueszer", transliterator.transliterate("chüsser")
  end

  test "multi-character rules may contain ascii and combining marks" do
    rule = { "sch" => "sh", "o\x0308" => "oe" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "shoen", transliterator.transliterate("scho\x0308n")
  end

  test "multi-character rules may contain supplementary plane characters" do
    rule = { "a😀b" => "SMILE" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "SMILEc", transliterator.transliterate("a😀bc")
    assert_equal "a?b", transliterator.transliterate("a😀b".sub("😀", "😎"))
  end

  test "the longest matching source fragment wins" do
    rule = { "a" => "X", "ab" => "Y", "abc" => "Z" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "ZYX", transliterator.transliterate("abcaba")
  end

  test "a shorter terminal rule still fires when a longer path fails" do
    assert_equal "Y?", I18n::Backend::Transliterator.get(
      { "ab" => "Y" }).transliterate("ab☃")
    assert_equal "ab?", I18n::Backend::Transliterator.get(
      { "abc" => "L" }).transliterate("ab☃")
  end

  test "rules of equal length keep the first one after nfc normalization" do
    ohm = [0x2126].pack("U*")   # OHM SIGN, NFC-normalizes to Greek omega
    omega = [0x03A9].pack("U*") # GREEK CAPITAL LETTER OMEGA
    rule = { ohm => "first", omega => "second", "i18n:nfc" => true }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "first", transliterator.transliterate(omega)
    assert_equal "first", transliterator.transliterate(ohm)
    assert_equal "first", transliterator.transliterate(omega)
  end

  test "empty rule keys are rejected" do
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get({ "" => "x" })
    end
  end

  test "keys that normalize to an empty string are rejected" do
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get({ "" => "x" })
    end
    assert_raises I18n::ArgumentError do
      I18n::Backend::Transliterator.get({ "" => "x", "i18n:nfc" => true })
    end
  end

  test "replacement text is not matched again" do
    rule = { "ae" => "ae", "ü" => "ue" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "aeue", transliterator.transliterate("aeü")

    recursive = I18n::Backend::Transliterator.get({ "ab" => "ba" })
    assert_equal "ba", recursive.transliterate("ab")
  end

  test "replacement may be an empty string" do
    rule = { "abc" => "", "ü" => "" }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "X", transliterator.transliterate("abcX")
    assert_equal "oe", transliterator.transliterate("üoe")
  end

  test "frozen input is transliterated without mutation errors" do
    transliterator = I18n::Backend::Transliterator.get({ "ü" => "ue" })
    input = "für".freeze
    assert_equal "fuer", transliterator.transliterate(input)
    assert input.frozen?
    assert_equal "für", input
  end

  test "nfc option matches decomposed input when enabled" do
    char = [117, 776].pack("U*") # "ü" as ASCII "u" plus COMBINING DIAERESIS
    transliterator = I18n::Backend::Transliterator.get(@hash.merge("i18n:nfc" => true))
    assert_equal "ue", transliterator.transliterate(char)
    assert_equal "ue", transliterator.transliterate("ü")
  end

  test "nfc option normalizes multi-character rules and input together" do
    char = [117, 776].pack("U*")
    rule = { char + char => "double", "i18n:nfc" => true }
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "double!", transliterator.transliterate("üü!")
  end

  test "decomposed input stays unmatched without nfc option" do
    char = [117, 776].pack("U*")
    transliterator = I18n::Backend::Transliterator.get(@hash)
    refute_equal "ue", transliterator.transliterate(char)
  end

  test "nfc keyword argument forces normalization independently of the rule hash" do
    char = [117, 776].pack("U*")
    transliterator = I18n::Backend::Transliterator.get(@hash, :nfc => true)
    assert_equal "ue", transliterator.transliterate(char)
  end

  test "nfc keyword argument can opt out of a rule hash option" do
    char = [117, 776].pack("U*")
    transliterator = I18n::Backend::Transliterator.get(
      @hash.merge("i18n:nfc" => true), :nfc => false)
    refute_equal "ue", transliterator.transliterate(char)
  end

  test "many shared-prefix rules match without scanning every rule" do
    keys = (1..500).map { |index| "prefix#{index}" }
    rule = keys.each_with_object({}) { |key, hash| hash[key] = key.upcase }
    rule["prefix"] = "P"
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_equal "PREFIX499", transliterator.transliterate("prefix499")
    assert_equal "P", transliterator.transliterate("prefix")
  end

  test "many shared-prefix rules run in linear time for unmatched input" do
    rule = (1..500).each_with_object({}) do |index, hash|
      hash["prefix#{index}"] = "x"
    end
    transliterator = I18n::Backend::Transliterator.get(rule)
    assert_match(/\A\?+\z/, transliterator.transliterate("☃" * 100))
  end

  test "switching locale immediately uses that locale's multi-character rules" do
    store_translations(:en, :i18n => {:transliterate => {:rule => { "sch" => "sh" }}})
    store_translations(:de, :i18n => {:transliterate => {:rule => { "sch" => "ch" }}})
    I18n.locale = :en
    assert_equal "sh", I18n.transliterate("sch")
    I18n.locale = :de
    assert_equal "ch", I18n.transliterate("sch")
    I18n.locale = :en
    assert_equal "sh", I18n.transliterate("sch")
  end

  test "nfc option stored with the locale rules is used through I18n" do
    char = [117, 776].pack("U*")
    store_translations(:xx, :i18n => {:transliterate => {:rule =>
      { "ü" => "ue", "i18n:nfc" => true }}})
    assert_equal "ue", I18n.transliterate(char, :locale => :xx)
  end

end
