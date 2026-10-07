# frozen_string_literal: true

require 'test_helper'

class I18nBackendMaskedSimpleTest < I18n::TestCase
  MASKED = I18n::Backend::MASKED

  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    store_translations(:en,
      :foo          => 'Foo',
      :masked_leaf  => MASKED,
      :masked_ns    => MASKED,
      :ns           => { :a => 'A', :b => MASKED, :deep => { :c => MASKED, :d => 'D' } },
      :nil_value    => nil,
      :false_value  => false,
      :empty_value  => '',
      :plural       => { :one => MASKED, :other => 'many' },
      :target       => MASKED,
      :alias_key    => :target)
  end

  test "masked leaf translates as missing" do
    assert_equal 'Translation missing: en.masked_leaf (masked)', I18n.t(:masked_leaf)
  end

  test "masked leaf raises MissingTranslationData with :raise" do
    assert_raises(I18n::MissingTranslationData) { I18n.t(:masked_leaf, :raise => true) }
  end

  test "masked leaf does not exist" do
    assert_equal false, I18n.exists?(:masked_leaf)
    assert_equal true,  I18n.exists?(:foo)
  end

  test "masked namespace masks the whole subtree" do
    assert_equal 'Translation missing: en.masked_ns (masked)', I18n.t(:masked_ns)
    assert_equal 'Translation missing: en.masked_ns.deep (masked)', I18n.t(:'masked_ns.deep')
    assert_equal false, I18n.exists?(:masked_ns)
    assert_equal false, I18n.exists?(:'masked_ns.deep')
  end

  test "masked leaves are stripped from namespace translations" do
    assert_equal({ :a => 'A', :deep => { :d => 'D' } }, I18n.t(:ns))
  end

  test "non-symbol default is still honored for masked keys" do
    assert_equal 'Default', I18n.t(:masked_leaf, :default => 'Default')
    assert_equal 'Default', I18n.t(:'masked_ns.deep', :default => 'Default')
    assert_nil I18n.t(:masked_leaf, :default => nil)
  end

  test "symbol default is resolved for masked keys" do
    assert_equal 'Foo', I18n.t(:masked_leaf, :default => :foo)
  end

  test "nil, false and empty string values keep their original semantics" do
    assert_equal 'Translation missing: en.nil_value', I18n.t(:nil_value)
    assert_equal 'default', I18n.t(:nil_value, :default => 'default')
    assert_equal false, I18n.t(:false_value)
    assert_equal '', I18n.t(:empty_value)
    assert_equal true, I18n.exists?(:false_value)
    assert_equal true, I18n.exists?(:empty_value)
  end

  test "alias pointing to a masked key resolves as missing" do
    assert_equal 'Translation missing: en.alias_key', I18n.t(:alias_key)
    assert_equal false, I18n.exists?(:alias_key)
  end

  test "unmasking restores the translation and aliases pointing to it" do
    store_translations(:en, :target => 'Back')
    assert_equal 'Back', I18n.t(:target)
    assert_equal 'Back', I18n.t(:alias_key)
    assert_equal true, I18n.exists?(:alias_key)
  end

  test "masked pluralization form is missing and does not leak the marker" do
    assert_equal 'many', I18n.t(:plural, :count => 2)
    assert_equal 'Translation missing: en.plural (masked)', I18n.t(:plural, :count => 1)
    assert_equal 'Default', I18n.t(:plural, :count => 1, :default => 'Default')
  end
end

class I18nBackendMaskedChainTest < I18n::TestCase
  MASKED = I18n::Backend::MASKED

  def setup
    super
    @upper = I18n::Backend::Simple.new
    @lower = I18n::Backend::Simple.new
    @upper.store_translations(:en,
      :masked_leaf => MASKED,
      :masked_ns   => MASKED,
      :ns          => { :b => MASKED })
    @lower.store_translations(:en,
      :masked_leaf => 'Lower Leaf',
      :masked_ns   => { :x => 'X' },
      :ns          => { :a => 'A', :b => 'B' },
      :other       => 'Other')
    I18n.backend = I18n::Backend::Chain.new(@upper, @lower)
  end

  test "masked leaf does not fall through to lower backends" do
    assert_equal 'Translation missing: en.masked_leaf (masked)', I18n.t(:masked_leaf)
    assert_equal false, I18n.exists?(:masked_leaf)
  end

  test "masked namespace does not fall through to lower backends" do
    assert_equal 'Translation missing: en.masked_ns (masked)', I18n.t(:masked_ns)
    assert_equal 'Translation missing: en.masked_ns.x (masked)', I18n.t(:'masked_ns.x')
    assert_equal false, I18n.exists?(:masked_ns)
    assert_equal false, I18n.exists?(:'masked_ns.x')
  end

  test "unmasked keys still resolve through the chain" do
    assert_equal 'Other', I18n.t(:other)
    assert_equal true, I18n.exists?(:other)
  end

  test "masked leaves inside a namespace suppress lower backends when merging" do
    assert_equal({ :a => 'A' }, I18n.t(:ns))
  end

  test "non-symbol default is still honored for masked keys" do
    assert_equal 'Default', I18n.t(:masked_leaf, :default => 'Default')
    assert_nil I18n.t(:masked_leaf, :default => nil)
  end

  test "unmasking restores the lower backend translation" do
    @upper.store_translations(:en, :masked_leaf => nil)
    assert_equal 'Lower Leaf', I18n.t(:masked_leaf)
    assert_equal true, I18n.exists?(:masked_leaf)
  end

  test "unmasking a namespace restores the lower backend subtree" do
    @upper.store_translations(:en, :masked_ns => nil)
    assert_equal({ :x => 'X' }, I18n.t(:masked_ns))
    assert_equal 'X', I18n.t(:'masked_ns.x')
  end
end

class I18nBackendMaskedFallbacksTest < I18n::TestCase
  MASKED = I18n::Backend::MASKED

  class Backend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    I18n.backend = Backend.new
    store_translations(:en, :foo => 'Foo in :en', :bar => 'Bar in :en')
    store_translations(:de, :foo => MASKED)
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:de => [:en])
  end

  test "masked translation does not fall back to other locales" do
    assert_equal 'Translation missing: de.foo (masked)', I18n.t(:foo, :locale => :de)
    assert_equal false, I18n.exists?(:foo, :locale => :de)
  end

  test "ordinary misses still fall back" do
    assert_equal 'Bar in :en', I18n.t(:bar, :locale => :de)
    assert_equal true, I18n.exists?(:bar, :locale => :de)
  end

  test "non-symbol default is still honored for masked keys" do
    assert_equal 'Default', I18n.t(:foo, :locale => :de, :default => 'Default')
    assert_nil I18n.t(:foo, :locale => :de, :default => nil)
  end

  test "other locales are unaffected by the mask" do
    assert_equal 'Foo in :en', I18n.t(:foo, :locale => :en)
    assert_equal true, I18n.exists?(:foo, :locale => :en)
  end

  test "unmasking restores the fallback locale translation" do
    store_translations(:de, :foo => nil)
    assert_equal 'Foo in :en', I18n.t(:foo, :locale => :de)
    assert_equal true, I18n.exists?(:foo, :locale => :de)
  end
end

class I18nBackendMaskedChainWithFallbacksTest < I18n::TestCase
  MASKED = I18n::Backend::MASKED

  class Backend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    @upper = Backend.new
    @lower = Backend.new
    @lower.store_translations(:en, :foo => 'Common Foo', :bar => :foo)
    @lower.store_translations(:de, :foo => 'Common Foo in :de')
    @upper.store_translations(:de, :foo => MASKED)
    I18n.backend = I18n::Backend::Chain.new(@upper, @lower)
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:de => [:en])
  end

  test "mask in upper backend stops both lower backends and fallback locales" do
    assert_equal 'Translation missing: de.foo (masked)', I18n.t(:foo, :locale => :de)
    assert_equal false, I18n.exists?(:foo, :locale => :de)
  end

  test "other locales are unaffected by the mask" do
    assert_equal 'Common Foo', I18n.t(:foo, :locale => :en)
    assert_equal true, I18n.exists?(:foo, :locale => :en)
  end

  test "alias in lower backend pointing to a masked key resolves as missing" do
    assert_equal 'Translation missing: de.bar', I18n.t(:bar, :locale => :de)
    assert_equal false, I18n.exists?(:bar, :locale => :de)
    assert_equal 'Common Foo', I18n.t(:bar, :locale => :en)
  end

  test "unmasking restores lower backend translations and aliases pointing to them" do
    @upper.store_translations(:de, :foo => nil)
    assert_equal 'Common Foo in :de', I18n.t(:foo, :locale => :de)
    assert_equal true, I18n.exists?(:foo, :locale => :de)
    assert_equal 'Common Foo in :de', I18n.t(:bar, :locale => :de)
    assert_equal true, I18n.exists?(:bar, :locale => :de)
  end
end
